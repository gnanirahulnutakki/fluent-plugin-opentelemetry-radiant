# frozen_string_literal: true

require "helper"
require "fluent/test/driver/output"
require "fluent/plugin/out_opentelemetry_radiant"
require "tmpdir"
require "socket"
require "timeout"

class OpentelemetryTransportTest < Test::Unit::TestCase
  Output = Fluent::Plugin::OpentelemetryRadiantOutput
  Otel = Fluent::Plugin::Opentelemetry
  LogsRequest = Opentelemetry::Proto::Collector::Logs::V1::ExportLogsServiceRequest

  class CapturingService
    attr_reader :calls
    attr_accessor :response, :error

    def initialize
      @calls = []
      @response = Otel::Response::Logs.build
    end

    def export(message, **options)
      @calls << [message, options]
      raise @error if @error

      @response
    end

    alias export_request export
  end

  class ReceivingLogs < Opentelemetry::Proto::Collector::Logs::V1::LogsService::Service
    attr_reader :received

    def initialize
      @received = Queue.new
    end

    def export(request, call)
      @received << [request, call.metadata]
      Otel::Response::Logs.build(rejected: 1, error: "test backend rejection")
    end
  end

  def setup
    Fluent::Test.setup
  end

  def teardown
    Excon.stubs.clear
    @grpc_handlers&.each { |h| h.instance_variable_get(:@channel).close }
  end

  def driver(protocol = :http, extra: "", section: "", endpoint: nil)
    endpoint ||= protocol == :http ? "http://127.0.0.1:4318" : "127.0.0.1:4317"
    d = Fluent::Test::Driver::Output.new(Output).configure(<<~CONF)
      #{extra}
      <#{protocol}>
        endpoint #{endpoint}
        #{section}
      </#{protocol}>
    CONF
    (@grpc_handlers ||= []) << handler(d, :grpc) if protocol == :grpc
    d
  end

  def handler(driver, protocol = :http)
    driver.instance.instance_variable_get("@#{protocol}_handler")
  end

  def request
    Otel::LogRecordBuilder.new(
      body_key: "message", body_format: :string, severity_key: "severity", attributes_from_record: true,
      exclude_keys: [], resource_attributes: {}, resource_attributes_from_record: {}, scope_name: "test",
      clock: -> { 123_000_000_456 }
    ).build("fid.log", [[Fluent::EventTime.new(123, 456), {
      "message" => "FID log line", "hostname" => "fid-0", "clustername" => "test", "log_type" => "access"
    }]])
  end

  def relay(type = "logs", message = nil)
    message ||= { "logs" => '{"resourceLogs":[]}', "metrics" => '{"resourceMetrics":[]}',
                  "traces" => '{"resourceSpans":[]}' }.fetch(type)
    { "type" => "opentelemetry_#{type}", "message" => message }
  end

  def mock_http(output_handler, status: 200, body: "", headers: {})
    output_handler.instance_variable_get(:@connections).each_value { |connection| connection.data[:mock] = true }
    received = []
    Excon.stub(method: :post) do |params|
      received << params
      { status: status, body: body, headers: headers }
    end
    received
  end

  def replace_method(receiver, name, replacement)
    singleton = receiver.singleton_class
    own_method = singleton.instance_methods(false).include?(name)
    original = receiver.method(name)
    singleton.send(:remove_method, name) if own_method
    singleton.send(:define_method, name, replacement)
    yield
  ensure
    singleton.send(:remove_method, name)
    singleton.send(:define_method, name, original) if own_method
  end

  def with_pems
    Dir.mktmpdir("otel-transport-test-") do |dir|
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = OpenSSL::X509::Name.parse("/CN=localhost")
      cert.issuer = cert.subject
      cert.public_key = key.public_key
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + 3600
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
      paths = { ca: File.join(dir, "ca.pem"), key: File.join(dir, "key.pem"), cert: File.join(dir, "cert.pem") }
      File.write(paths[:ca], cert.to_pem)
      File.write(paths[:cert], cert.to_pem)
      File.write(paths[:key], key.to_pem, perm: 0o600)
      yield paths, key, cert
    end
  end

  def test_headers_are_masked_by_fluentd_config_dump_and_not_logged
    token = "test-only-header-secret"
    d = driver(extra: %(headers {"Authorization":"Bearer #{token}","X-Account":"test-only-account-secret"}))
    assert_equal "Bearer #{token}", d.instance.headers.fetch("Authorization")
    dump = d.instance.config.to_s
    raw_dump = d.instance.instance_variable_get(:@config).to_s
    assert_include dump, "headers xxxxxx"
    [dump, raw_dump, d.logs.join].each do |text|
      assert_not_include text, token
      assert_not_include text, "test-only-account-secret"
    end
  end

  def test_http_headers_reach_every_export_and_reserved_headers_cannot_be_overridden
    [:text, :gzip].each do |compression|
      d = driver(extra: 'headers {"Authorization":"Bearer test-token","content-type":"bad/type","CONTENT-ENCODING":"br"}',
                 section: "compress #{compression}")
      h = handler(d)
      received = mock_http(h)
      h.export_logs(request)
      %w[logs metrics traces].each { |type| h.export(relay(type)) }
      assert_equal 4, received.size
      received.each do |params|
        assert_equal "Bearer test-token", params[:headers]["Authorization"]
        types = params[:headers].select { |key, _| key.downcase == "content-type" }
        assert_equal ["application/x-protobuf"], types.values
        encodings = params[:headers].select { |key, _| key.downcase == "content-encoding" }
        assert_equal(compression == :gzip ? ["gzip"] : [], encodings.values)
      end
      encoded = received.first[:body]
      encoded = Zlib::GzipReader.new(StringIO.new(encoded)).read if compression == :gzip
      assert_equal request.resource_logs.first.scope_logs.first.log_records.first.body, LogsRequest.decode(encoded).resource_logs.first.scope_logs.first.log_records.first.body
      Excon.stubs.clear
    end
  end

  def test_http_connections_are_created_once_reused_and_strip_trailing_slashes
    h = handler(driver(endpoint: "http://127.0.0.1:4318/prefix///"))
    connections = h.instance_variable_get(:@connections).dup
    received = mock_http(h)
    replace_method(Excon, :new, ->(*) { flunk "connection recreated during export" }) do
      2.times do
        h.export_logs(request)
        %w[logs metrics traces].each { |type| h.export(relay(type)) }
      end
    end
    assert_equal connections, h.instance_variable_get(:@connections)
    assert_equal ["/prefix/v1/logs", "/prefix/v1/metrics", "/prefix/v1/traces"], received.map { |params| params[:path] }.uniq
    assert connections.values.all? { |connection| connection.data[:persistent] }
  end

  def test_http_tls_options_are_per_connection_and_leave_excon_defaults_untouched
    defaults = Marshal.load(Marshal.dump(Excon.defaults))
    d = driver(endpoint: "https://localhost:4318", extra: <<~CONF)
      <transport tls>
        ca_path /test/ca.pem
        cert_path /test/client.pem
        private_key_path /test/key.pem
        private_key_passphrase test-passphrase
        min_version TLSv1_2
        max_version TLSv1_3
        insecure true
      </transport>
    CONF
    handler(d).instance_variable_get(:@connections).each_value do |connection|
      data = connection.data
      assert_equal "/test/ca.pem", data[:ssl_ca_file]
      assert_equal "/test/client.pem", data[:client_cert]
      assert_equal "/test/key.pem", data[:client_key]
      assert_equal "test-passphrase", data[:client_key_pass]
      assert_equal OpenSSL::SSL::TLS1_2_VERSION, data[:ssl_min_version]
      assert_equal OpenSSL::SSL::TLS1_3_VERSION, data[:ssl_max_version]
      assert_equal false, data[:ssl_verify_peer]
    end
    assert_equal defaults, Excon.defaults
    secure = handler(driver(endpoint: "https://localhost:4318", extra: "<transport tls>\n</transport>"))
    assert secure.instance_variable_get(:@connections).values.all? { |connection| connection.data[:ssl_verify_peer] }
    assert_equal defaults, Excon.defaults
  end

  def test_insecure_http_warns_once_at_start
    d = driver(extra: "<transport tls>\n insecure true\n</transport>")
    assert_empty d.logs.grep(/certificate verification is off/)
    begin
      d.instance.start
      h = handler(d)
      mock_http(h)
      2.times { h.export_logs(request) }
      assert_equal 1, d.logs.grep(/certificate verification is off/).size
    ensure
      %i[stop before_shutdown shutdown after_shutdown close terminate].each { |method| d.instance.public_send(method) }
    end
  end

  def test_http_all_2xx_statuses_succeed_and_always_consume_response_body
    h = handler(driver)
    [200, 201, 202, 204, 206, 299, 400, 503].each do |status|
      reads = 0
      response = Object.new
      response.define_singleton_method(:status) { status }
      response.define_singleton_method(:body) { reads += 1; "" }
      connection = Object.new
      connection.define_singleton_method(:post) { response }
      if status < 300
        assert_nothing_raised { h.send(:post, "test-uri", connection) }
      else
        assert_raise(status == 400 ? Fluent::UnrecoverableError : Output::RetryableResponse) { h.send(:post, "test-uri", connection) }
      end
      assert_equal 1, reads
    end
  end

  def test_http_network_errors_stay_retryable
    h = handler(driver)
    h.instance_variable_get(:@connections).each_value { |connection| connection.data[:mock] = true }
    Excon.stub(method: :post) { raise Excon::Error::Socket, Errno::ECONNREFUSED.new }
    assert_raise(Excon::Error::Socket) { h.export_logs(request) }
  end

  def test_http_partial_success_warns_without_retry_for_both_log_paths_and_redacts_secrets
    response = Otel::Response::Logs.build(rejected: 3, error: "bad record with test-secret")
    [[:protobuf, response.to_proto, "application/x-protobuf"], [:json, response.to_json, "application/json"]].each do |_, body, content_type|
      d = driver(extra: 'headers {"Authorization":"test-secret"}')
      h = handler(d)
      received = mock_http(h, status: 202, body: body, headers: { "Content-Type" => content_type })
      h.export_logs(request)
      h.export(relay)
      assert_equal 2, received.size
      assert_equal 2, d.logs.grep(/rejected_log_records=3/).size
      assert_include d.logs.join, "bad record with [REDACTED]"
      assert_not_include d.logs.join, "test-secret"
      Excon.stubs.clear
    end
  end

  def test_http_success_with_unparseable_response_does_not_retry
    d = driver
    h = handler(d)
    mock_http(h, status: 200, body: "not protobuf")
    assert_nothing_raised { h.export_logs(request) }
    assert_include d.logs.join, "Could not decode successful OTLP logs response"
  end

  def test_buffer_and_grpc_defaults
    instance = driver(:grpc).instance
    assert_equal ["tag"], instance.buffer_config.chunk_keys
    assert_equal 2 * 1024 * 1024, instance.buffer_config.chunk_limit_size
    assert_equal({}, instance.headers)
    assert_equal :text, instance.grpc_config.compress
    assert_equal 60, instance.grpc_config.timeout
    assert_equal 30, instance.grpc_config.keepalive_time
    assert_equal 10, instance.grpc_config.keepalive_timeout
  end

  def test_grpc_rejects_uri_endpoints_and_missing_port
    ["https://localhost:4317", "http://localhost:4317", "localhost", "localhost:4317/path"].each do |endpoint|
      error = assert_raise(Fluent::ConfigError) { driver(:grpc, endpoint: endpoint) }
      assert_include error.message, "host:port"
      assert_include error.message, "<transport tls>"
    end
  end

  def test_grpc_rejects_insecure_verification
    error = assert_raise(Fluent::ConfigError) do
      driver(:grpc, extra: "<transport tls>\n insecure true\n</transport>")
    end
    assert_equal "certificate verification cannot be turned off for gRPC; set ca_path to the server's CA instead", error.message
  end

  def test_grpc_tls_credentials_are_built_from_files_at_configure_time
    with_pems do |paths, key, cert|
      calls = []
      original = GRPC::Core::ChannelCredentials.method(:new)
      replace_method(GRPC::Core::ChannelCredentials, :new, ->(*args) { calls << args; original.call(*args) }) do
        driver(:grpc, extra: <<~CONF)
          <transport tls>
            ca_path #{paths[:ca]}
            cert_path #{paths[:cert]}
            private_key_path #{paths[:key]}
          </transport>
        CONF
      end
      assert_equal [[cert.to_pem, key.to_pem, cert.to_pem]], calls
    end
  end

  def test_grpc_tls_system_roots_and_plaintext
    calls = []
    original = GRPC::Core::ChannelCredentials.method(:new)
    replace_method(GRPC::Core::ChannelCredentials, :new, ->(*args) { calls << args; original.call(*args) }) do
      driver(:grpc)
      assert_empty calls
      driver(:grpc, extra: "<transport tls>\n</transport>")
      assert_equal [[nil, nil, nil]], calls
    end
  end

  def test_grpc_unreadable_tls_files_name_the_file_in_config_error
    %w[ca_path cert_path private_key_path].each do |param|
      Dir.mktmpdir("otel-missing-pem-") do |dir|
        path = File.join(dir, "missing.pem")
        error = assert_raise(Fluent::ConfigError) do
          driver(:grpc, extra: "<transport tls>\n #{param} #{path}\n</transport>")
        end
        assert_include error.message, path
      end
    end
  end

  def test_grpc_client_certificate_requires_a_key
    with_pems do |paths, _, _|
      error = assert_raise(Fluent::ConfigError) do
        driver(:grpc, extra: "<transport tls>\n cert_path #{paths[:cert]}\n</transport>")
      end
      assert_include error.message, "both cert_path and private_key_path"
    end
  end

  def test_grpc_encrypted_client_key_is_decrypted_before_building_credentials
    with_pems do |paths, key, cert|
      File.write(paths[:key], key.export(OpenSSL::Cipher.new("aes-256-cbc"), "test-passphrase"))
      calls = []
      original = GRPC::Core::ChannelCredentials.method(:new)
      replace_method(GRPC::Core::ChannelCredentials, :new, ->(*args) { calls << args; original.call(*args) }) do
        driver(:grpc, extra: <<~CONF)
          <transport tls>
            cert_path #{paths[:cert]}
            private_key_path #{paths[:key]}
            private_key_passphrase test-passphrase
          </transport>
        CONF
      end
      assert_equal [[nil, key.to_pem, cert.to_pem]], calls
      error = assert_raise(Fluent::ConfigError) do
        driver(:grpc, extra: <<~CONF)
          <transport tls>
            cert_path #{paths[:cert]}
            private_key_path #{paths[:key]}
            private_key_passphrase wrong-passphrase
          </transport>
        CONF
      end
      assert_include error.message, paths[:key]
      assert_not_include error.message, "wrong-passphrase"
      assert_nil error.cause
    end
  end

  def test_grpc_mismatched_pair_at_configure_time_is_passed_through_as_in_0_1_0
    with_pems do |paths, _, cert|
      other_key = OpenSSL::PKey::RSA.new(2048)
      File.write(paths[:key], other_key.to_pem)
      calls = []
      original = GRPC::Core::ChannelCredentials.method(:new)
      replace_method(GRPC::Core::ChannelCredentials, :new, ->(*args) { calls << args; original.call(*args) }) do
        driver(:grpc, extra: "<transport tls>\n cert_path #{paths[:cert]}\n private_key_path #{paths[:key]}\n</transport>")
      end
      assert_equal [[nil, other_key.to_pem, cert.to_pem]], calls
    end
  end

  def test_grpc_key_without_client_certificate_is_config_error
    with_pems do |paths, _, _|
      error = assert_raise(Fluent::ConfigError) do
        driver(:grpc, extra: "<transport tls>\n private_key_path #{paths[:key]}\n</transport>")
      end
      assert_include error.message, "both cert_path and private_key_path"
    end
  end

  def test_grpc_stubs_created_once_with_plaintext_compression_and_keepalive_args
    services = [Otel::GrpcOutputHandler::ServiceStub::Logs, Otel::GrpcOutputHandler::ServiceStub::Metrics,
                Otel::GrpcOutputHandler::ServiceStub::Traces]
    calls = []
    channel_calls = []
    original = GRPC::Core::Channel.method(:new)
    channel_constructor = ->(*args) { channel_calls << args; original.call(*args) }
    replacement = ->(*args, **options) { calls << [args, options]; CapturingService.new }
    replace_method(GRPC::Core::Channel, :new, channel_constructor) do
      replace_method(services[0], :new, replacement) do
        replace_method(services[1], :new, replacement) do
          replace_method(services[2], :new, replacement) do
            d = driver(:grpc, section: "compress gzip\n keepalive_time 45\n keepalive_timeout 12")
            h = handler(d, :grpc)
            2.times do
              h.export_logs(request)
              %w[logs metrics traces].each { |type| h.export(relay(type)) }
            end
            assert_equal [h.instance_variable_get(:@channel)], calls.map { |_, options| options[:channel_override] }.uniq
          end
        end
      end
    end
    assert_equal 3, calls.size
    assert_equal 1, channel_calls.size
    expected = GRPC::Core::CompressionOptions.new(default_algorithm: :gzip).to_channel_arg_hash.merge(
      "grpc.keepalive_time_ms" => 45_000, "grpc.keepalive_timeout_ms" => 12_000,
      "grpc.keepalive_permit_without_calls" => 1, "grpc.primary_user_agent" => "grpc-ruby/#{GRPC::VERSION}"
    )
    assert_equal ["127.0.0.1:4317", expected, :this_channel_is_insecure], channel_calls.first
    calls.each do |args, options|
      assert_equal ["127.0.0.1:4317", :this_channel_is_insecure], args
      assert_equal [:channel_override], options.keys
    end
  end

  def test_grpc_headers_and_per_call_deadlines_reach_records_and_all_relay_stubs
    d = driver(:grpc, extra: 'headers {"Authorization":"Bearer token","X-Tenant-ID":"tenant","Content-Type":"bad","Content-Encoding":"br"}',
               section: "timeout 7")
    h = handler(d, :grpc)
    # Capture the generated stub's export call, so the wrapper's keyword
    # forwarding and relay protobuf decoding are exercised as well.
    stubs = h.instance_variable_get(:@services).values.map { |service| service.instance_variable_get(:@stub) }
    captured = []
    stubs.each do |stub|
      stub.define_singleton_method(:export) do |message, **options|
        captured << [message, options]
        message.is_a?(LogsRequest) ? Otel::Response::Logs.build : nil
      end
    end
    before = Time.now
    h.export_logs(request)
    %w[logs metrics traces].each { |type| h.export(relay(type)) }
    after = Time.now
    assert_equal 4, captured.size
    assert_instance_of LogsRequest, captured.first.first
    captured.each do |_, options|
      assert_equal({ "authorization" => "Bearer token", "x-tenant-id" => "tenant" }, options[:metadata])
      assert_operator options[:deadline], :>=, before + 7
      assert_operator options[:deadline], :<=, after + 7
    end
  end

  def test_grpc_retryable_and_unrecoverable_status_codes
    d = driver(:grpc, extra: 'headers {"Authorization":"test-secret"}')
    h = handler(d, :grpc)
    service = CapturingService.new
    h.instance_variable_get(:@services)[Otel::RECORD_TYPE_LOGS] = service
    retryable = %i[CANCELLED DEADLINE_EXCEEDED ABORTED OUT_OF_RANGE UNAVAILABLE DATA_LOSS RESOURCE_EXHAUSTED]
    GRPC::Core::StatusCodes.constants.each do |name|
      next if name == :OK

      code = GRPC::Core::StatusCodes.const_get(name)
      service.error = GRPC::BadStatus.new_status_exception(code, "backend details test-secret")
      expected = retryable.include?(name) ? Output::RetryableResponse : Fluent::UnrecoverableError
      error = assert_raise(expected, name.to_s) { h.export_logs(request) }
      assert_include error.message, name.to_s
      assert_include error.message, "backend details [REDACTED]"
      assert_not_include error.message, "test-secret"
      assert_nil error.cause
    end
  end

  def test_relay_grpc_status_keeps_upstream_retry_behavior_and_redacts_echoed_headers
    d = driver(:grpc, extra: 'headers {"Authorization":"test-secret"}')
    h = handler(d, :grpc)
    service = CapturingService.new
    service.error = GRPC::Unauthenticated.new("invalid test-secret", { "echo" => "test-secret" })
    h.instance_variable_get(:@services)[Otel::RECORD_TYPE_LOGS] = service
    error = assert_raise(GRPC::Unauthenticated) { h.export(relay) }
    assert_include error.message, "invalid [REDACTED]"
    assert_not_include error.message, "test-secret"
    assert_empty error.metadata
    assert_nil error.cause
  end

  def test_http_error_echoing_a_header_is_redacted_before_fluentd_logs_it
    h = handler(driver(extra: 'headers {"Authorization":"test-secret"}'))
    h.instance_variable_get(:@connections).each_value { |connection| connection.data[:mock] = true }
    Excon.stub(method: :post) { raise Excon::Error, "proxy echoed test-secret" }
    error = assert_raise(Output::RetryableResponse) { h.export_logs(request) }
    assert_include error.message, "proxy echoed [REDACTED]"
    assert_not_include error.message, "test-secret"
    assert_nil error.cause
  end

  def test_grpc_partial_success_warns_without_retry_for_both_log_paths
    d = driver(:grpc)
    h = handler(d, :grpc)
    service = CapturingService.new
    service.response = Otel::Response::Logs.build(rejected: 5, error: "bad records")
    h.instance_variable_get(:@services)[Otel::RECORD_TYPE_LOGS] = service
    h.export_logs(request)
    h.export(relay)
    assert_equal 2, service.calls.size
    assert_equal 2, d.logs.grep(/rejected_log_records=5.*bad records/).size
  end

  def test_real_plaintext_grpc_round_trip_sends_metadata_and_fid_records
    # Probe in Ruby first: native gRPC can abort the process when binding is
    # denied by a sandbox. This omission must remain visible in test output.
    begin
      probe = TCPServer.new("127.0.0.1", 0)
      probe.close
    rescue Errno::EPERM, Errno::EACCES => e
      omit("sandbox forbids the local TCP listener required by the real gRPC test: #{e.message}")
    end
    server = GRPC::RpcServer.new
    port = server.add_http2_port("127.0.0.1:0", :this_port_is_insecure)
    service = ReceivingLogs.new
    server.handle(service)
    thread = Thread.new { server.run_till_terminated }
    assert server.wait_till_running(5), "local gRPC server did not start"
    d = driver(:grpc, endpoint: "127.0.0.1:#{port}", section: "compress gzip\n timeout 5",
               extra: 'headers {"Authorization":"Bearer wire-token","X-Tenant":"fid-test"}')
    h = handler(d, :grpc)
    expected = request
    h.export_logs(expected)
    h.export(relay("logs", expected.to_json))
    2.times do
      received, metadata = Timeout.timeout(5) { service.received.pop }
      assert_equal expected, received
      assert_equal "Bearer wire-token", metadata["authorization"]
      assert_equal "fid-test", metadata["x-tenant"]
      log = received.resource_logs.first.scope_logs.first.log_records.first
      assert_equal "FID log line", log.body.string_value
      attributes = log.attributes.to_h { |attribute| [attribute.key, attribute.value.string_value] }
      assert_equal({ "hostname" => "fid-0", "clustername" => "test", "log_type" => "access", "fluent.tag" => "fid.log" }, attributes)
    end
    assert_equal 2, d.logs.grep(/rejected_log_records=1/).size
  ensure
    server&.stop if server&.running?
    if thread
      thread.join(5)
      thread.kill.join if thread.alive?
    end
  end

  def tls_config(paths, passphrase: nil)
    <<~CONF
      <transport tls>
        ca_path #{paths[:ca]}
        cert_path #{paths[:cert]}
        private_key_path #{paths[:key]}
        #{"private_key_passphrase #{passphrase}" if passphrase}
      </transport>
    CONF
  end

  def replace_methods(replacements, &block)
    return block.call if replacements.empty?

    receiver, name, replacement = replacements.first
    replace_method(receiver, name, replacement) { replace_methods(replacements.drop(1), &block) }
  end

  def with_grpc_spies
    credentials, channels, services = [], [], []
    original_credentials = GRPC::Core::ChannelCredentials.method(:new)
    original_channel = GRPC::Core::Channel.method(:new)
    replacements = [
      [GRPC::Core::ChannelCredentials, :new, ->(*args) { credentials << args; original_credentials.call(*args) }],
      [GRPC::Core::Channel, :new, ->(*args) { original_channel.call(*args).tap { |channel| channels << channel } }]
    ]
    [Otel::GrpcOutputHandler::ServiceStub::Logs, Otel::GrpcOutputHandler::ServiceStub::Metrics,
     Otel::GrpcOutputHandler::ServiceStub::Traces].each do |klass|
      replacements << [klass, :new, ->(*, **options) {
        service = CapturingService.new
        services << [service, options.fetch(:channel_override)]
        service
      }]
    end
    replace_methods(replacements) { yield credentials, channels, services }
  ensure
    channels&.each(&:close)
  end

  def assert_channel_closed(channel)
    error = assert_raise(RuntimeError) { channel.connectivity_state }
    assert_equal "closed!", error.message
  end

  def tls_warnings(d)
    d.logs.grep(/keeping the current gRPC channel/)
  end

  def test_grpc_unchanged_tls_files_do_not_rebuild_or_warn
    with_pems do |paths, _, _|
      with_grpc_spies do |credentials, channels, services|
        d = driver(:grpc, extra: tls_config(paths))
        h = handler(d, :grpc)
        10.times do
          h.export_logs(request)
          %w[logs metrics traces].each { |type| h.export(relay(type)) }
        end
        assert_equal 1, credentials.size
        assert_equal 1, channels.size
        assert_equal [20, 10, 10], services.map { |service, _| service.calls.size }
        expected = { ca_path: paths[:ca], cert_path: paths[:cert], private_key_path: paths[:key] }
          .transform_values { |path| Digest::SHA256.hexdigest(File.binread(path)) }
        assert_equal expected, h.instance_variable_get(:@tls_fingerprints)
        assert_empty tls_warnings(d)
        assert_empty d.logs.grep(/gRPC TLS files changed/)
      end
    end
  end

  def test_grpc_changed_client_pair_rebuilds_all_stubs_once_and_closes_old_channel
    with_pems do |paths, _, _|
      with_pems do |_, key, cert|
        with_grpc_spies do |credentials, channels, services|
          d = driver(:grpc, extra: tls_config(paths))
          h = handler(d, :grpc)
          h.export_logs(request)
          File.write(paths[:cert], cert.to_pem)
          File.write(paths[:key], key.to_pem)
          h.export_logs(request)
          %w[logs metrics traces].each { |type| h.export(relay(type)) }
          assert_equal 2, credentials.size
          assert_equal [File.binread(paths[:ca]), key.to_pem, cert.to_pem], credentials.last
          assert_equal 2, channels.size
          assert_channel_closed(channels.first)
          assert_nothing_raised { channels.last.connectivity_state }
          assert_equal [1, 0, 0, 2, 1, 1], services.map { |service, _| service.calls.size }
          assert_equal [channels.last] * 3, services.last(3).map(&:last)
          assert_equal 1, d.logs.grep(/gRPC TLS files changed/).size
          assert_empty tls_warnings(d)
        end
      end
    end
  end

  def test_grpc_changed_ca_only_rebuilds_on_relay_export
    with_pems do |paths, key, cert|
      with_pems do |_, _, new_ca|
        with_grpc_spies do |credentials, channels, _|
          d = driver(:grpc, extra: tls_config(paths))
          h = handler(d, :grpc)
          updated_ca = new_ca.to_pem
          File.write(paths[:ca], updated_ca)
          h.export(relay("metrics"))
          h.export_logs(request)
          assert_equal 2, credentials.size
          assert_equal [updated_ca, key.to_pem, cert.to_pem], credentials.last
          assert_channel_closed(channels.first)
          assert_equal 1, d.logs.grep(/gRPC TLS files changed/).size
        end
      end
    end
  end

  def test_grpc_repeated_rotations_close_every_retired_channel
    with_pems do |paths, _, _|
      with_grpc_spies do |credentials, channels, _|
        d = driver(:grpc, extra: tls_config(paths))
        h = handler(d, :grpc)
        5.times do
          File.write(paths[:ca], File.binread(paths[:ca]) + "\n")
          h.export_logs(request)
        end
        assert_equal 6, credentials.size
        assert_equal 6, channels.size
        channels[0...-1].each { |channel| assert_channel_closed(channel) }
        assert_nothing_raised { channels.last.connectivity_state }
        assert_equal 5, d.logs.grep(/gRPC TLS files changed/).size
        assert_empty tls_warnings(d)
      end
    end
  end

  def test_grpc_kubernetes_secret_symlink_swap_rebuilds_once
    with_pems do |paths, _, _|
      with_pems do |replacement_paths, _, _|
        dir = File.dirname(paths[:ca])
        %w[..version1 ..version2].each { |name| Dir.mkdir(File.join(dir, name)) }
        paths.each do |kind, path|
          File.rename(path, File.join(dir, "..version1", File.basename(path)))
          File.write(File.join(dir, "..version2", File.basename(path)), File.binread(replacement_paths[kind]))
          File.symlink(File.join("..data", File.basename(path)), path)
        end
        File.symlink("..version1", File.join(dir, "..data"))
        with_grpc_spies do |credentials, channels, _|
          d = driver(:grpc, extra: tls_config(paths))
          h = handler(d, :grpc)
          File.symlink("..version2", File.join(dir, "..data_tmp"))
          File.rename(File.join(dir, "..data_tmp"), File.join(dir, "..data"))
          3.times { h.export_logs(request) }
          assert_equal 2, credentials.size
          assert_equal replacement_paths.values_at(:ca, :key, :cert).map { |path| File.binread(path) }, credentials.last
          assert_channel_closed(channels.first)
          assert_equal 1, d.logs.grep(/gRPC TLS files changed/).size
        end
      end
    end
  end

  def test_grpc_missing_file_keeps_old_stub_warns_once_and_recovers
    with_pems do |paths, _, _|
      with_grpc_spies do |credentials, channels, services|
        d = driver(:grpc, extra: tls_config(paths))
        h = handler(d, :grpc)
        ca = File.binread(paths[:ca])
        File.unlink(paths[:ca])
        3.times { h.export_logs(request) }
        assert_equal 3, services.first.first.calls.size
        assert_equal 1, credentials.size
        assert_nothing_raised { channels.first.connectivity_state }
        assert_equal 1, tls_warnings(d).size
        assert_include tls_warnings(d).first, paths[:ca]
        File.write(paths[:ca], ca + "\n")
        h.export_logs(request)
        assert_equal 2, credentials.size
        assert_equal 1, services[3].first.calls.size
        assert_channel_closed(channels.first)
        File.unlink(paths[:ca])
        h.export_logs(request)
        assert_equal 2, tls_warnings(d).size
      end
    end
  end

  def test_grpc_invalid_rotated_pair_and_bad_passphrase_keep_old_stub_and_warn_once
    with_pems do |paths, key, cert|
      with_pems do |_, other_key, _|
        with_grpc_spies do |credentials, channels, services|
          d = driver(:grpc, extra: tls_config(paths, passphrase: "test-passphrase"))
          h = handler(d, :grpc)
          File.write(paths[:key], other_key.to_pem)
          2.times { h.export_logs(request) }
          assert_equal 1, tls_warnings(d).size
          assert_include tls_warnings(d).first, paths[:key]
          assert_include tls_warnings(d).first, paths[:cert]
          File.write(paths[:key], key.export(OpenSSL::Cipher.new("aes-256-cbc"), "different-passphrase"))
          2.times { h.export(relay) }
          assert_equal 2, tls_warnings(d).size
          assert_include tls_warnings(d).last, paths[:key]
          assert_equal 1, credentials.size
          assert_equal 4, services.first.first.calls.size
          assert_nothing_raised { channels.first.connectivity_state }
          [key.to_pem, other_key.to_pem, cert.to_pem, "test-passphrase", "different-passphrase"].each do |secret|
            assert_not_include d.logs.join, secret
          end
          File.write(paths[:key], key.export(OpenSSL::Cipher.new("aes-256-cbc"), "test-passphrase"))
          h.export_logs(request)
          assert_equal 2, credentials.size
          assert_equal key.to_pem, credentials.last[1]
          assert_channel_closed(channels.first)
        end
      end
    end
  end

  def test_grpc_distinct_read_failures_warn_once_each_until_a_successful_check
    with_pems do |paths, _, _|
      with_grpc_spies do |_, _, _|
        d = driver(:grpc, extra: tls_config(paths))
        h = handler(d, :grpc)
        ca, key = File.binread(paths[:ca]), File.binread(paths[:key])
        File.unlink(paths[:key])
        h.export_logs(request)
        File.unlink(paths[:ca])
        h.export_logs(request)
        File.write(paths[:ca], ca)
        h.export_logs(request)
        assert_equal 2, tls_warnings(d).size
        File.write(paths[:key], key)
        h.export_logs(request)
        File.unlink(paths[:key])
        h.export_logs(request)
        assert_equal 3, tls_warnings(d).size
      end
    end
  end

  def test_grpc_concurrent_exports_rebuild_exactly_once
    with_pems do |paths, _, _|
      with_grpc_spies do |credentials, channels, services|
        d = driver(:grpc, extra: tls_config(paths))
        h = handler(d, :grpc)
        File.write(paths[:ca], File.binread(paths[:ca]) + "\n")
        ready, start = Queue.new, Queue.new
        threads = 8.times.map do |index|
          Thread.new do
            ready << true
            start.pop
            index.even? ? h.export_logs(request) : h.export(relay)
          end
        end
        Timeout.timeout(3) { 8.times { ready.pop } }
        8.times { start << true }
        Timeout.timeout(3) { threads.each(&:value) }
        assert_equal 2, credentials.size
        assert_equal 2, channels.size
        assert_equal 8, services[3].first.calls.size
        assert_equal 1, d.logs.grep(/gRPC TLS files changed/).size
        assert_channel_closed(channels.first)
      ensure
        threads&.each { |thread| thread.kill.join if thread.alive? }
      end
    end
  end

  def test_grpc_rotation_defers_old_channel_close_until_its_active_export_finishes
    with_pems do |paths, _, _|
      with_grpc_spies do |_, channels, services|
        d = driver(:grpc, extra: tls_config(paths))
        h = handler(d, :grpc)
        entered, finish = Queue.new, Queue.new
        services.first.first.define_singleton_method(:export_request) do |*, **|
          entered << true
          finish.pop
          Otel::Response::Logs.build
        end
        thread = Thread.new { h.export_logs(request) }
        Timeout.timeout(3) { entered.pop }
        File.write(paths[:ca], File.binread(paths[:ca]) + "\n")
        h.export_logs(request)
        assert_nothing_raised { channels.first.connectivity_state }
        finish << true
        Timeout.timeout(3) { thread.value }
        assert_channel_closed(channels.first)
        assert_nothing_raised { channels.last.connectivity_state }
      ensure
        thread.kill.join if thread&.alive?
      end
    end
  end

  def test_grpc_failed_stub_construction_closes_candidate_channel_and_keeps_old_stubs
    with_pems do |paths, _, _|
      with_grpc_spies do |_, channels, services|
        d = driver(:grpc, extra: tls_config(paths))
        h = handler(d, :grpc)
        File.write(paths[:ca], File.binread(paths[:ca]) + "\n")
        replace_method(Otel::GrpcOutputHandler::ServiceStub::Metrics, :new, ->(*) { raise "test construction failure" }) do
          2.times { h.export_logs(request) }
        end
        assert_equal 2, services.first.first.calls.size
        assert_equal 1, tls_warnings(d).size
        channels.drop(1).each { |channel| assert_channel_closed(channel) }
        assert_nothing_raised { channels.first.connectivity_state }
        h.export_logs(request)
        assert_channel_closed(channels.first)
        assert_nothing_raised { channels.last.connectivity_state }
      end
    end
  end

  def test_grpc_plaintext_exports_never_read_tls_files
    with_grpc_spies do |credentials, _, _|
      d = driver(:grpc)
      h = handler(d, :grpc)
      no_read = ->(*) { flunk "plaintext export read a TLS file" }
      replace_methods([[File, :read, no_read], [File, :binread, no_read]]) do
        3.times do
          h.export_logs(request)
          %w[logs metrics traces].each { |type| h.export(relay(type)) }
        end
      end
      assert_empty credentials
      assert_empty tls_warnings(d)
    end
  end

  def issue_certificate(name, issuer: nil, purpose: nil)
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = OpenSSL::BN.rand(64).to_i
    cert.subject = OpenSSL::X509::Name.parse("/CN=#{name}")
    cert.issuer = issuer ? issuer.last.subject : cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    extensions = OpenSSL::X509::ExtensionFactory.new
    extensions.subject_certificate = cert
    extensions.issuer_certificate = issuer ? issuer.last : cert
    cert.add_extension(extensions.create_extension("basicConstraints", issuer ? "CA:FALSE" : "CA:TRUE", true))
    cert.add_extension(extensions.create_extension("keyUsage", issuer ? "digitalSignature,keyEncipherment" : "keyCertSign,cRLSign", true))
    cert.add_extension(extensions.create_extension("extendedKeyUsage", purpose)) if purpose
    cert.add_extension(extensions.create_extension("subjectAltName", "IP:127.0.0.1")) if purpose == "serverAuth"
    cert.sign(issuer ? issuer.first : key, OpenSSL::Digest.new("SHA256"))
    [key, cert]
  end

  def start_mtls_server(port, server_pair, client_ca)
    key, cert = server_pair
    credentials = GRPC::Core::ServerCredentials.new(
      client_ca.to_pem, [{ private_key: key.to_pem, cert_chain: cert.to_pem }], true
    )
    server = GRPC::RpcServer.new(poll_period: 0.1, pool_keep_alive: 0.1)
    bound_port = server.add_http2_port("127.0.0.1:#{port}", credentials)
    assert_operator bound_port, :>, 0
    assert_equal port, bound_port unless port.zero?
    service = ReceivingLogs.new
    server.handle(service)
    thread = Thread.new { server.run_till_terminated }
    assert server.wait_till_running(2), "local mutual TLS server did not start"
    [server, thread, service, bound_port]
  rescue StandardError
    stop_mtls_server(server, thread)
    raise
  end

  def stop_mtls_server(server, thread)
    server&.stop if server&.running?
    return unless thread

    assert thread.join(2), "local mutual TLS server did not stop"
    thread.value
  ensure
    thread.kill.join if thread&.alive?
  end

  def test_real_mtls_grpc_rotation_reconnects_to_same_endpoint_without_recreating_handler
    begin
      probe = TCPServer.new("127.0.0.1", 0)
      probe.close
    rescue Errno::EPERM, Errno::EACCES => e
      omit("sandbox forbids the local TCP listener required by the mutual TLS rotation test: #{e.message}")
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    server_ca = issue_certificate("server CA S")
    client_ca_a = issue_certificate("client CA A")
    client_ca_b = issue_certificate("client CA B")
    server_pair = issue_certificate("localhost", issuer: server_ca, purpose: "serverAuth")
    client_a = issue_certificate("client A", issuer: client_ca_a, purpose: "clientAuth")
    client_b = issue_certificate("client B", issuer: client_ca_b, purpose: "clientAuth")
    Dir.mktmpdir("otel-mtls-rotation-") do |dir|
      paths = { ca: File.join(dir, "ca.pem"), cert: File.join(dir, "client.pem"), key: File.join(dir, "client-key.pem") }
      File.write(paths[:ca], server_ca.last.to_pem)
      File.write(paths[:cert], client_a.last.to_pem)
      File.write(paths[:key], client_a.first.to_pem, perm: 0o600)
      server, thread, service, port = start_mtls_server(0, server_pair, client_ca_a.last)
      d = driver(:grpc, endpoint: "127.0.0.1:#{port}", section: "timeout 1", extra: tls_config(paths))
      h = handler(d, :grpc)
      original_channel = h.instance_variable_get(:@channel)
      expected = request
      h.export_logs(expected)
      assert_equal expected, Timeout.timeout(1) { service.received.pop }.first
      stop_mtls_server(server, thread)
      server, thread, service, bound_port = start_mtls_server(port, server_pair, client_ca_b.last)
      assert_equal port, bound_port

      # Unchanged files keep the A credentials, which the B-only server rejects.
      error = assert_raise(Output::RetryableResponse) { h.export_logs(expected) }
      assert_match(/UNAVAILABLE|DEADLINE_EXCEEDED/, error.message)
      assert service.received.empty?
      assert_same original_channel, h.instance_variable_get(:@channel)
      assert_empty d.logs.grep(/gRPC TLS files changed/)

      File.write(paths[:cert], client_b.last.to_pem)
      File.write(paths[:key], client_b.first.to_pem)
      begin
        h.export_logs(expected)
      rescue Output::RetryableResponse
        h.export_logs(expected)
      end
      assert_equal expected, Timeout.timeout(1) { service.received.pop }.first
      assert_not_same original_channel, h.instance_variable_get(:@channel)
      assert_channel_closed(original_channel)
      h.export(relay("logs", expected.to_json))
      assert_equal expected, Timeout.timeout(1) { service.received.pop }.first
      assert_equal 1, d.logs.grep(/gRPC TLS files changed/).size
      assert_empty tls_warnings(d)
    ensure
      stop_mtls_server(server, thread)
      h&.instance_variable_get(:@channel)&.close
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 10, "mutual TLS rotation test took #{elapsed.round(2)} seconds"
  end
end
