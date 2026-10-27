# frozen_string_literal: true

require "helper"
require "fluent/test/driver/input"
require "fluent/plugin/in_opentelemetry"
require "protocol/http/headers"
require "protocol/http/body/buffered"
require "stringio"
require "zlib"

class OpentelemetryInputLimitsTest < Test::Unit::TestCase
  Otel = Fluent::Plugin::Opentelemetry

  class Body < Protocol::HTTP::Body::Buffered
    attr_reader :reads, :closed

    def initialize(chunks)
      super(chunks)
      @reads = 0
      @closed = false
    end

    def read
      @reads += 1
      super
    end

    def close(*args)
      @closed = true
      super
    end
  end

  def setup
    Fluent::Test.setup
    @driver = Fluent::Test::Driver::Input.new(Fluent::Plugin::OpentelemetryInput).configure(<<~CONF)
      tag otel.${type}
      <http>
        body_size_limit 128
        decompression_size_limit 256
      </http>
    CONF
    @handler = Otel::HttpInputHandler.new(@driver.instance.http_config, @driver.instance.log)
  end

  def request(chunks, headers = {})
    @body = Body.new(chunks)
    underlying = Struct.new(:path, :headers, :body).new(
      "/v1/logs", Protocol::HTTP::Headers[{ "content-type" => "application/json" }.merge(headers)], @body
    )
    req = Fluent::PluginHelper::HttpServer::Request.new(underlying)
    # The security fix must use the stream, never the unbounded convenience API.
    req.define_singleton_method(:body) { raise "unbounded request.body must not be called" }
    req
  end

  def export(req, method = :logs)
    @emitted = []
    @handler.public_send(method, req) { |record| @emitted << record }
  end

  def gzip(body)
    writer = Zlib::GzipWriter.new(StringIO.new)
    writer << body
    writer.close.string
  end

  def test_input_limit_defaults_and_constant_compatibility
    d = Fluent::Test::Driver::Input.new(Fluent::Plugin::OpentelemetryInput).configure("tag otel\n<http>\n</http>")
    assert_equal 32 * 1024 * 1024, d.instance.http_config.body_size_limit
    assert_equal 256 * 1024 * 1024, d.instance.http_config.decompression_size_limit
    assert_equal "text/plain", Otel::CONTENT_TYPE_PLAIN
    assert_equal Otel::CONTENT_TYPE_PLAIN, Otel::CONTENT_TYPE_PAIN
  end

  def test_content_length_over_limit_returns_413_without_reading_and_closes
    result = export(request(["{}"], "content-length" => "129"))
    assert_equal 413, result.first
    assert_equal 0, @body.reads
    assert @body.closed
    assert_empty @emitted
  end

  def test_streamed_body_without_content_length_is_limited_and_closes_early
    result = export(request([" " * 64, " " * 65, "must not read this chunk"]))
    assert_equal 413, result.first
    assert_equal 2, @body.reads
    assert @body.closed
    assert_empty @emitted
  end

  def test_stream_limit_is_enforced_even_when_content_length_understates_the_body
    result = export(request([" " * 129], "content-length" => "1"))
    assert_equal 413, result.first
    assert @body.closed
    assert_empty @emitted
  end

  def test_exact_body_limit_is_accepted_with_or_without_content_length
    [nil, "128"].each do |length|
      headers = length ? { "content-length" => length } : {}
      result = export(request(["{}" + " " * 126], headers))
      assert_equal 200, result.first
      assert_equal 1, @emitted.size
      assert @body.closed
    end
  end

  def test_gzip_expansion_limit_returns_413
    result = export(request([gzip(" " * 257)], "content-encoding" => "gzip"))
    assert_equal 413, result.first
    assert @body.closed
    assert_empty @emitted
  end

  def test_concatenated_gzip_members_share_one_decompression_limit
    compressed = gzip(" " * 128) + gzip(" " * 129)
    result = export(request([compressed], "content-encoding" => "gzip"))
    assert_equal 413, result.first
    assert @body.closed
    assert_empty @emitted
  end

  def test_bad_gzip_and_truncated_gzip_return_400_and_close
    valid = gzip('{"resourceLogs":[]}')
    ["not gzip", valid[0...-4], valid[0...-8], valid[0...8], valid + "trailing garbage"].each do |body|
      result = export(request([body], "content-encoding" => "gzip"))
      assert_equal 400, result.first
      assert @body.closed
      assert_empty @emitted
    end
  end

  def test_valid_gzip_at_exact_decompression_limit_succeeds
    result = export(request([gzip("{}" + " " * 254)], "content-encoding" => "gzip"))
    assert_equal 200, result.first
    assert_equal 1, @emitted.size
    assert @body.closed
  end

  def test_json_protobuf_and_multi_chunk_bodies_reach_all_signal_callbacks
    %i[logs metrics traces].each do |method|
      response = export(request(["{", "}"]), method)
      assert_equal 200, response.first
      assert_equal 1, @emitted.size
      assert @body.closed
      response = export(request(["".b], "content-type" => "application/x-protobuf"), method)
      assert_equal 200, response.first
      assert_equal 1, @emitted.size
      assert @body.closed
    end
  end

  def test_invalid_content_type_encoding_and_protobuf_close_the_body
    [{ "content-type" => "text/plain" }, { "content-encoding" => "br" }, {}].each_with_index do |headers, index|
      result = export(request(["not valid protobuf"], headers))
      assert_equal(index.zero? ? 415 : 400, result.first)
      assert @body.closed
      assert_empty @emitted
    end
  end

  def test_callback_failure_still_closes_request
    req = request(["{}"])
    assert_raise(RuntimeError) { @handler.logs(req) { raise "callback failed" } }
    assert @body.closed
  end

  def test_grpc_input_stop_stops_the_retained_server
    server = Object.new
    stopped = false
    server.define_singleton_method(:stop) { stopped = true }
    config = Struct.new(:bind, :port).new("127.0.0.1", 0)
    handler = Otel::GrpcInputHandler.new(config, @driver.instance.log)
    handler.instance_variable_set(:@server, server)
    handler.stop
    assert stopped
  end

  def test_input_plugin_stop_calls_grpc_handler
    stopped = false
    handler = Object.new
    handler.define_singleton_method(:stop) { stopped = true }
    @driver.instance.instance_variable_set(:@grpc_handler, handler)
    @driver.instance.stop
    assert stopped
  end
end
