# frozen_string_literal: true

# Copyright 2026 Radiant Logic, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

require "socket"
require "timeout"

saved_http_proxy = ENV.delete("HTTP_PROXY")
saved_http_proxy_lower = ENV.delete("http_proxy")
begin
  require "helper"
  require "fluent/msgpack_factory"
  require "fluent/test/driver/output"
  require "fluent/plugin/in_opentelemetry"
  require "fluent/plugin/in_opentelemetry_metrics"
  require "fluent/plugin/out_opentelemetry"
ensure
  ENV["HTTP_PROXY"] = saved_http_proxy if saved_http_proxy
  ENV["http_proxy"] = saved_http_proxy_lower if saved_http_proxy_lower
end

class OpentelemetryRadiantOutputTest < Test::Unit::TestCase
  OBSERVED_TIME_UNIX_NANO = 1_788_393_600_987_654_321
  ChunkMetadata = Struct.new(:tag)

  class TestChunk
    attr_reader :metadata

    def initialize(tag, events)
      @metadata = ChunkMetadata.new(tag)
      @events = events
    end

    def msgpack_each(&block)
      @events.each(&block)
    end
  end

  class CapturingHandler
    attr_reader :relay_records, :log_requests

    def initialize
      @relay_records = []
      @log_requests = []
    end

    def export(record)
      @relay_records << record
    end

    def export_logs(request)
      @log_requests << request
    end
  end

  class StaticHttpConnection
    Response = Struct.new(:status, :body)

    def initialize(status)
      @response = Response.new(status, "")
    end

    def post
      @response
    end
  end

  class CapturingGrpcService
    attr_reader :requests

    def initialize
      @requests = []
    end

    def export_request(request, **_options)
      @requests << request
      Fluent::Plugin::Opentelemetry::Response::Logs.build
    end
  end

  class OneShotHttpServer
    attr_reader :port

    def initialize(status)
      @status = status
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @thread = Thread.new { serve }
      @thread.report_on_exception = false
    end

    def wait
      Timeout.timeout(5) { @thread.join }
      raise @error if @error

      @request
    end

    def close
      @server.close unless @server.closed?
      @thread.kill if @thread.alive?
      @thread.join
    end

    private

    def serve
      socket = @server.accept
      request_line = socket.gets&.strip
      headers = {}
      while (line = socket.gets)
        break if line == "\r\n"

        name, value = line.split(":", 2)
        headers[name.downcase] = value.strip
      end
      body = socket.read(headers.fetch("content-length", "0").to_i)
      @request = { request_line: request_line, headers: headers, body: body }

      reason = @status == 200 ? "OK" : "Error"
      socket.write("HTTP/1.1 #{@status} #{reason}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    rescue StandardError => e
      @error = e
    ensure
      socket&.close
    end
  end

  def setup
    Fluent::Test.setup
  end

  def create_driver(extra_config = "", endpoint: "http://127.0.0.1:4318", http_config: "")
    Fluent::Test::Driver::Output.new(Fluent::Plugin::OpentelemetryRadiantOutput).configure(<<~CONFIG)
      #{extra_config}
      <http>
        endpoint #{endpoint}
        #{http_config}
      </http>
    CONFIG
  end

  def capture_request(driver, tag, events)
    handler = CapturingHandler.new
    driver.instance.instance_variable_set(:@http_handler, handler)
    builder = driver.instance.instance_variable_get(:@log_record_builder)
    builder.instance_variable_set(:@clock, -> { OBSERVED_TIME_UNIX_NANO })
    driver.instance.write(TestChunk.new(tag, events))
    assert_equal 1, handler.log_requests.length
    handler.log_requests.first
  end

  def resource_and_scope(request)
    resource_logs = request.resource_logs.fetch(0)
    [resource_logs.resource, resource_logs.scope_logs.fetch(0)]
  end

  def key_values_by_name(key_values)
    key_values.to_h { |attribute| [attribute.key, attribute.value] }
  end

  def local_http_server(status)
    OneShotHttpServer.new(status)
  rescue Errno::EPERM => e
    omit("sandbox forbids the local TCP listener required by this integration test: #{e.message}")
  end

  def test_configuration_defaults_and_buffer_contract
    instance = create_driver.instance

    assert_equal :auto, instance.mode
    assert_equal "message", instance.body_key
    assert_equal :string, instance.body_format
    assert_equal "severity", instance.severity_key
    assert_true instance.attributes_from_record
    assert_equal [], instance.exclude_keys
    assert_equal({}, instance.resource_attributes)
    assert_equal({}, instance.resource_attributes_from_record)
    assert_equal "fluent-plugin-opentelemetry-radiant", instance.scope_name
    assert_equal ["tag"], instance.buffer_config.chunk_keys
    assert_true instance.formatted_to_msgpack_binary?
    assert_true instance.multi_workers_ready?
  end

  def test_format_preserves_event_time_nanoseconds_in_msgpack_pair
    instance = create_driver.instance
    time = Fluent::EventTime.new(1_788_393_600, 123_456_789)
    record = { "message" => "preserve me" }

    unpacker = Fluent::MessagePackFactory.msgpack_unpacker
    unpacker.feed(instance.format("fid.access", time, record))
    unpacked_time, unpacked_record = unpacker.read

    assert_instance_of Fluent::EventTime, unpacked_time
    assert_equal time.sec, unpacked_time.sec
    assert_equal time.nsec, unpacked_time.nsec
    assert_equal record, unpacked_record
  end

  def test_fluentd_buffer_round_trip_preserves_nanoseconds_and_builds_one_request
    driver = create_driver(<<~CONFIG)
      mode records
      <buffer tag>
        @type memory
        flush_mode immediate
        flush_at_shutdown true
      </buffer>
    CONFIG
    handler = CapturingHandler.new
    driver.instance.instance_variable_set(:@http_handler, handler)
    builder = driver.instance.instance_variable_get(:@log_record_builder)
    builder.instance_variable_set(:@clock, -> { OBSERVED_TIME_UNIX_NANO })
    time = Fluent::EventTime.new(1_788_393_600, 987_654_321)

    begin
      driver.run(default_tag: "fid.access") do
        driver.feed(time, { "message" => "buffered" })
      end
    rescue Errno::EPERM => e
      omit("sandbox forbids Fluentd's socket manager required by this buffer integration test: #{e.message}")
    end

    assert_equal 1, handler.log_requests.length
    _, scope_logs = resource_and_scope(handler.log_requests.first)
    assert_equal 1_788_393_600_987_654_321, scope_logs.log_records.first.time_unix_nano
  end

  def test_converts_typed_record_fields_resource_attributes_scope_and_severity
    driver = create_driver(<<~CONFIG)
      mode records
      exclude_keys password
      resource_attributes {"service.name":"fid","service.instance.id":7}
      resource_attributes_from_record {"host.name":"hostname"}
      scope_name radiant.fid.access
    CONFIG
    time = Fluent::EventTime.new(1_788_393_600, 123_456_789)
    first_record = {
      "message" => "connected",
      "severity" => "wArN",
      "hostname" => "fid-0",
      "sequence" => 42,
      "ratio" => 1.5,
      "healthy" => true,
      "context" => { "attempt" => 2 },
      "roles" => ["reader", 3, false],
      "nothing" => nil,
      "password" => "do-not-export"
    }
    second_record = { "message" => "second", "hostname" => "fid-1" }

    request = capture_request(driver, "fid.access", [[time, first_record], [time, second_record]])
    resource, scope_logs = resource_and_scope(request)
    resource_attributes = key_values_by_name(resource.attributes)
    log_record = scope_logs.log_records.fetch(0)
    attributes = key_values_by_name(log_record.attributes)

    assert_equal 2, scope_logs.log_records.length
    assert_equal "radiant.fid.access", scope_logs.scope.name
    assert_equal "fid", resource_attributes.fetch("service.name").string_value
    assert_equal 7, resource_attributes.fetch("service.instance.id").int_value
    assert_equal "fid-0", resource_attributes.fetch("host.name").string_value
    assert_equal 1_788_393_600_123_456_789, log_record.time_unix_nano
    assert_equal OBSERVED_TIME_UNIX_NANO, log_record.observed_time_unix_nano
    assert_equal "connected", log_record.body.string_value
    assert_equal "wArN", log_record.severity_text
    assert_equal :SEVERITY_NUMBER_WARN, log_record.severity_number
    assert_equal "fid-0", attributes.fetch("hostname").string_value
    assert_equal 42, attributes.fetch("sequence").int_value
    assert_in_delta 1.5, attributes.fetch("ratio").double_value
    assert_true attributes.fetch("healthy").bool_value
    assert_equal 2, key_values_by_name(attributes.fetch("context").kvlist_value.values).fetch("attempt").int_value
    role_values = []
    attributes.fetch("roles").array_value.values.each do |value|
      converted_value =
        case value.value
        when :string_value then value.string_value
        when :int_value then value.int_value
        when :bool_value then value.bool_value
        end
      role_values << converted_value
    end
    assert_equal ["reader", 3, false], role_values
    assert_equal "null", attributes.fetch("nothing").string_value
    assert_equal "fid.access", attributes.fetch("fluent.tag").string_value
    assert_false attributes.key?("message")
    assert_false attributes.key?("severity")
    assert_false attributes.key?("password")
  end

  def test_missing_body_key_serializes_the_whole_record_as_json_and_leaves_severity_unset
    driver = create_driver("mode records")
    time = Fluent::EventTime.new(1_788_393_600, 5)
    record = { "LOGID" => 1, "OPNAME" => "Connect" }

    request = capture_request(driver, "fid.access", [[time, record]])
    _, scope_logs = resource_and_scope(request)
    log_record = scope_logs.log_records.fetch(0)
    attributes = key_values_by_name(log_record.attributes)

    assert_equal record, JSON.parse(log_record.body.string_value)
    assert_equal "", log_record.severity_text
    assert_equal :SEVERITY_NUMBER_UNSPECIFIED, log_record.severity_number
    assert_equal 1, attributes.fetch("LOGID").int_value
    assert_equal "Connect", attributes.fetch("OPNAME").string_value
  end

  def test_chunk_with_invalid_binary_text_keeps_all_records_in_one_request
    driver = create_driver("mode records")
    messages = ["first", "bad\xFFbyte".b, "a\xC2\xA0b".b, "last"]
    events = messages.map { |message| [1_788_393_600, { "message" => message }] }

    request = capture_request(driver, "fid.access", events)
    decoded = request.class.decode(request.to_proto)
    _, scope_logs = resource_and_scope(decoded)

    assert_equal ["first", "bad\uFFFDbyte", "a\u00A0b", "last"], scope_logs.log_records.map { |record| record.body.string_value }
  end

  def test_kvlist_body_contains_the_whole_record_with_native_types
    driver = create_driver(<<~CONFIG)
      mode records
      body_format kvlist
    CONFIG
    record = {
      "message" => "connected",
      "severity" => "INFO",
      "meta" => { "port" => 2389 },
      "flags" => [true, "audit"]
    }

    request = capture_request(driver, "fid.access", [[1_788_393_600, record]])
    _, scope_logs = resource_and_scope(request)
    body_values = key_values_by_name(scope_logs.log_records.fetch(0).body.kvlist_value.values)

    assert_equal "connected", body_values.fetch("message").string_value
    assert_equal "INFO", body_values.fetch("severity").string_value
    assert_equal 2389, key_values_by_name(body_values.fetch("meta").kvlist_value.values).fetch("port").int_value
    flag_values = []
    body_values.fetch("flags").array_value.values.each do |value|
      flag_values << (value.value == :bool_value ? value.bool_value : value.string_value)
    end
    assert_equal [true, "audit"], flag_values
  end

  def test_attributes_can_be_disabled_but_fluent_tag_is_always_present
    driver = create_driver(<<~CONFIG)
      mode records
      attributes_from_record false
      exclude_keys fluent.tag
    CONFIG

    request = capture_request(driver, "fid.access", [[1_788_393_600, { "message" => "connected", "extra" => 1 }]])
    _, scope_logs = resource_and_scope(request)
    attributes = key_values_by_name(scope_logs.log_records.fetch(0).attributes)

    assert_equal ["fluent.tag"], attributes.keys
    assert_equal "fid.access", attributes.fetch("fluent.tag").string_value
  end

  def test_unknown_severity_uses_unspecified_number_and_retains_text
    driver = create_driver("mode records")

    request = capture_request(driver, "fid.access", [[1_788_393_600, { "message" => "x", "severity" => "NOTICE" }]])
    _, scope_logs = resource_and_scope(request)
    log_record = scope_logs.log_records.fetch(0)

    assert_equal "NOTICE", log_record.severity_text
    assert_equal :SEVERITY_NUMBER_UNSPECIFIED, log_record.severity_number
  end

  def test_auto_mode_partitions_mixed_chunk_between_relay_and_conversion
    driver = create_driver
    handler = CapturingHandler.new
    driver.instance.instance_variable_set(:@http_handler, handler)
    relay_records = [
      { "type" => "opentelemetry_logs", "message" => '{"resourceLogs":[]}' },
      { "type" => "opentelemetry_metrics", "message" => '{"resourceMetrics":[]}' },
      { "type" => "opentelemetry_traces", "message" => '{"resourceSpans":[]}' }
    ]
    ordinary = { "message" => "ordinary FID line", "severity" => "INFO" }
    events = relay_records.each_with_index.map { |record, index| [1_788_393_600 + index, record] }
    events << [1_788_393_603, ordinary]

    driver.instance.write(TestChunk.new("mixed.tag", events))

    assert_equal relay_records, handler.relay_records
    assert_equal 1, handler.log_requests.length
    _, scope_logs = resource_and_scope(handler.log_requests.first)
    assert_equal 1, scope_logs.log_records.length
    assert_equal "ordinary FID line", scope_logs.log_records.first.body.string_value
  end

  def test_relay_mode_passes_upstream_shaped_record_to_existing_export_path
    driver = create_driver("mode relay")
    handler = CapturingHandler.new
    driver.instance.instance_variable_set(:@http_handler, handler)
    relay = {
      "type" => "opentelemetry_logs",
      "message" => '{"resourceLogs":[]}'
    }

    # A relay-only chunk does not need tag metadata, matching the upstream path.
    driver.instance.write(TestChunk.new(nil, [[1_788_393_600, relay]]))

    assert_equal [relay], handler.relay_records
    assert_empty handler.log_requests
  end

  def test_output_and_input_plugin_names_resolve
    %w[opentelemetry_radiant opentelemetry].each do |type|
      assert_instance_of Fluent::Plugin::OpentelemetryRadiantOutput, Fluent::Plugin.new_output(type)
    end
    assert_instance_of Fluent::Plugin::OpentelemetryInput, Fluent::Plugin.new_input("opentelemetry")
    assert_instance_of Fluent::Plugin::OpentelemetryMetricsInput, Fluent::Plugin.new_input("opentelemetry_metrics")
  end

  def test_http_export_sends_protobuf_that_decodes_to_the_converted_request
    server = local_http_server(200)
    driver = create_driver("mode records", endpoint: "http://127.0.0.1:#{server.port}")
    builder = driver.instance.instance_variable_get(:@log_record_builder)
    builder.instance_variable_set(:@clock, -> { OBSERVED_TIME_UNIX_NANO })
    time = Fluent::EventTime.new(1_788_393_600, 123)
    events = [[time, { "message" => "wire test", "severity" => "ERROR", "attempt" => 2 }]]
    expected = builder.build("fid.access", events)

    driver.instance.write(TestChunk.new("fid.access", events))
    received = server.wait
    decoded = Opentelemetry::Proto::Collector::Logs::V1::ExportLogsServiceRequest.decode(received.fetch(:body))

    assert_equal "POST /v1/logs HTTP/1.1", received.fetch(:request_line)
    assert_equal "application/x-protobuf", received.fetch(:headers).fetch("content-type")
    assert_equal expected, decoded
  ensure
    server&.close
  end

  def test_prepared_http_request_uses_the_same_protobuf_wire_format_as_relay_logs
    driver = create_driver("mode records")
    handler = driver.instance.instance_variable_get(:@http_handler)
    prepared = capture_request(
      driver,
      "fid.access",
      [[1_788_393_600, { "message" => "wire format" }]]
    )

    prepared_headers, prepared_body = handler.send(:prepare_body, prepared.to_proto)
    relay_record = {
      "type" => "opentelemetry_logs",
      "message" => prepared.to_json
    }
    relay_uri, relay_headers, relay_body = handler.send(:get_post_data, relay_record)

    assert_equal "http://127.0.0.1:4318/v1/logs", relay_uri
    assert_equal "application/x-protobuf", prepared_headers.fetch("Content-Type")
    assert_equal prepared_headers, relay_headers
    assert_equal prepared.to_proto, prepared_body
    assert_equal prepared.to_proto, relay_body
  end

  def test_http_relay_keeps_logs_metrics_and_traces_routes_and_protobuf_encoding
    driver = create_driver("mode relay")
    handler = driver.instance.instance_variable_get(:@http_handler)
    cases = [
      ["opentelemetry_logs", '{"resourceLogs":[]}', "/v1/logs",
       Opentelemetry::Proto::Collector::Logs::V1::ExportLogsServiceRequest],
      ["opentelemetry_metrics", '{"resourceMetrics":[]}', "/v1/metrics",
       Opentelemetry::Proto::Collector::Metrics::V1::ExportMetricsServiceRequest],
      ["opentelemetry_traces", '{"resourceSpans":[]}', "/v1/traces",
       Opentelemetry::Proto::Collector::Trace::V1::ExportTraceServiceRequest]
    ]

    cases.each do |type, message, path, request_class|
      uri, _headers, body = handler.send(:get_post_data, { "type" => type, "message" => message })

      assert_equal "http://127.0.0.1:4318#{path}", uri
      assert_equal request_class.decode_json(message).to_proto, body
    end
  end

  def test_retryable_http_response_raises_for_fluentd_retry
    driver = create_driver("mode records")
    handler = driver.instance.instance_variable_get(:@http_handler)

    assert_raise(Fluent::Plugin::OpentelemetryOutput::RetryableResponse) do
      handler.send(:post, "http://127.0.0.1:4318/v1/logs", StaticHttpConnection.new(503))
    end
  end

  def test_http_400_is_unrecoverable_even_when_other_error_responses_are_recoverable
    driver = create_driver(
      "mode records",
      http_config: "error_response_as_unrecoverable false"
    )
    handler = driver.instance.instance_variable_get(:@http_handler)

    assert_raise(Fluent::UnrecoverableError) do
      handler.send(:post, "http://127.0.0.1:4318/v1/logs", StaticHttpConnection.new(400))
    end
  end

  def test_grpc_handler_exports_a_prepared_logs_request_without_json_reencoding
    unless defined?(Fluent::Plugin::Opentelemetry::GrpcOutputHandler)
      omit("the optional grpc gem is not installed")
    end

    request = capture_request(
      create_driver("mode records"),
      "fid.access",
      [[1_788_393_600, { "message" => "grpc" }]]
    )
    grpc_driver = Fluent::Test::Driver::Output.new(Fluent::Plugin::OpentelemetryRadiantOutput).configure(<<~CONFIG)
      <grpc>
        endpoint 127.0.0.1:4317
      </grpc>
    CONFIG
    handler = grpc_driver.instance.instance_variable_get(:@grpc_handler)
    service = CapturingGrpcService.new
    handler.define_singleton_method(:logs_service) { service }

    handler.export_logs(request)

    assert_equal [request], service.requests
  end
end
