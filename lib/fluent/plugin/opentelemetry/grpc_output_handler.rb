# frozen_string_literal: true

# Copyright 2025- Shizuo Fujita
# Copyright 2026 Radiant Logic, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
#
# Modified by Radiant Logic, Inc. to export prepared OTLP logs requests while
# retaining the upstream relay path.

require "opentelemetry/proto/collector/logs/v1/logs_service_pb"
require "opentelemetry/proto/collector/logs/v1/logs_service_services_pb"
require "opentelemetry/proto/collector/metrics/v1/metrics_service_pb"
require "opentelemetry/proto/collector/metrics/v1/metrics_service_services_pb"
require "opentelemetry/proto/collector/trace/v1/trace_service_pb"
require "opentelemetry/proto/collector/trace/v1/trace_service_services_pb"

require "fluent/plugin/opentelemetry/constant"
require "fluent/plugin/opentelemetry/output_response"
require "google/protobuf"
require "digest"
require "set"

class Fluent::Plugin::Opentelemetry::GrpcOutputHandler
  include Fluent::Plugin::Opentelemetry::OutputResponse

  RETRYABLE_CODES = %i[CANCELLED DEADLINE_EXCEEDED ABORTED OUT_OF_RANGE UNAVAILABLE DATA_LOSS RESOURCE_EXHAUSTED].map do |name|
    GRPC::Core::StatusCodes.const_get(name)
  end.freeze
  CODE_NAMES = GRPC::Core::StatusCodes.constants.to_h do |name|
    [GRPC::Core::StatusCodes.const_get(name), name.to_s]
  end.freeze

  class TlsFileError < StandardError; end

  class ServiceStub
    class Logs
      def initialize(host, creds, **kw)
        @stub = Opentelemetry::Proto::Collector::Logs::V1::LogsService::Stub.new(host, creds, **kw)
      end

      def export(json, **kw)
        message = Opentelemetry::Proto::Collector::Logs::V1::ExportLogsServiceRequest.decode_json(json)
        export_request(message, **kw)
      end

      def export_request(message, **kw)
        @stub.export(message, **kw)
      end
    end

    class Metrics
      def initialize(host, creds, **kw)
        @stub = Opentelemetry::Proto::Collector::Metrics::V1::MetricsService::Stub.new(host, creds, **kw)
      end

      def export(json, **kw)
        message = Opentelemetry::Proto::Collector::Metrics::V1::ExportMetricsServiceRequest.decode_json(json)
        @stub.export(message, **kw)
      end
    end

    class Traces
      def initialize(host, creds, **kw)
        @stub = Opentelemetry::Proto::Collector::Trace::V1::TraceService::Stub.new(host, creds, **kw)
      end

      def export(json, **kw)
        message = Opentelemetry::Proto::Collector::Trace::V1::ExportTraceServiceRequest.decode_json(json)
        @stub.export(message, **kw)
      end
    end
  end

  def initialize(grpc_config, transport_config, logger, headers = {})
    @grpc_config = grpc_config
    @logger = logger
    @headers = headers
    @metadata = headers.transform_keys(&:downcase).reject { |key, _| %w[content-type content-encoding].include?(key) }

    unless grpc_config.endpoint.match?(%r{\A(?:\[[^\]]+\]|[^:/\s]+):[0-9]+\z})
      raise Fluent::ConfigError, "gRPC endpoint must be host:port (without ://); use <transport tls> for TLS"
    end
    if transport_config&.insecure
      raise Fluent::ConfigError, "certificate verification cannot be turned off for gRPC; set ca_path to the server's CA instead"
    end

    @transport_config = transport_config
    @tls_mutex = Mutex.new
    @active_exports = Hash.new(0)
    @tls_failures = Set.new
    if transport_config&.protocol == :tls
      @tls_paths = {
        ca_path: transport_config.ca_path, cert_path: transport_config.cert_path,
        private_key_path: transport_config.private_key_path
      }.compact
    end
    pems = read_tls_files if @tls_paths
    credential = channel_credentials(pems)
    @tls_fingerprints = fingerprints(pems) if @tls_paths
    @channel_args = {}
    if grpc_config.compress == :gzip
      @channel_args = GRPC::Core::CompressionOptions.new(default_algorithm: :gzip).to_channel_arg_hash
    end
    @channel_args["grpc.keepalive_time_ms"] = grpc_config.keepalive_time * 1000
    @channel_args["grpc.keepalive_timeout_ms"] = grpc_config.keepalive_timeout * 1000
    @channel_args["grpc.keepalive_permit_without_calls"] = 1
    @channel_args["grpc.primary_user_agent"] = "grpc-ruby/#{GRPC::VERSION}"
    @channel, @services = build_services(credential)
  rescue TlsFileError => e
    raise Fluent::ConfigError, e.message, cause: nil
  end

  def export(record)
    response = with_service(record["type"]) do |service|
      raise Fluent::UnrecoverableError, "got unknown record type '#{record['type']}'" unless service

      service.export(record["message"], **call_options)
    end
    warn_partial_success(response) if record["type"] == Fluent::Plugin::Opentelemetry::RECORD_TYPE_LOGS
  rescue Google::Protobuf::ParseError => e
    raise Fluent::UnrecoverableError, e.message
  rescue GRPC::BadStatus => e
    # Preserve upstream relay retry behavior without exposing echoed credentials.
    raise GRPC::BadStatus.new_status_exception(e.code, redact_headers(e.details)), cause: nil
  end

  def export_logs(request)
    response = with_service(Fluent::Plugin::Opentelemetry::RECORD_TYPE_LOGS) do |service|
      service.export_request(request, **call_options)
    end
    warn_partial_success(response)
  rescue GRPC::BadStatus => e
    code_name = CODE_NAMES.fetch(e.code, e.code.to_s)
    message = "OTLP gRPC export failed: #{code_name}: #{redact_headers(e.details)}"
    error_class = RETRYABLE_CODES.include?(e.code) ? Fluent::Plugin::OpentelemetryOutput::RetryableResponse : Fluent::UnrecoverableError
    # Fluentd logs errors when retrying chunks. Do not retain a cause containing
    # unredacted server details or response metadata.
    raise error_class, message, cause: nil
  end

  private

  def logs_service
    @services.fetch(Fluent::Plugin::Opentelemetry::RECORD_TYPE_LOGS)
  end

  def service_for(type)
    type == Fluent::Plugin::Opentelemetry::RECORD_TYPE_LOGS ? logs_service : @services[type]
  end

  def with_service(type)
    return yield service_for(type) unless @tls_paths

    channel = nil
    service = @tls_mutex.synchronize do
      refresh_tls_files
      channel = @channel
      @active_exports[channel] += 1
      service_for(type)
    end
    yield service
  ensure
    if channel
      @tls_mutex.synchronize do
        @active_exports[channel] -= 1
        if @active_exports[channel].zero?
          @active_exports.delete(channel)
          channel.close unless channel.equal?(@channel)
        end
      end
    end
  end

  def build_services(credential)
    channel = GRPC::Core::Channel.new(@grpc_config.endpoint, @channel_args, credential)
    options = { channel_override: channel }
    services = {
      Fluent::Plugin::Opentelemetry::RECORD_TYPE_LOGS => ServiceStub::Logs.new(@grpc_config.endpoint, credential, **options),
      Fluent::Plugin::Opentelemetry::RECORD_TYPE_METRICS => ServiceStub::Metrics.new(@grpc_config.endpoint, credential, **options),
      Fluent::Plugin::Opentelemetry::RECORD_TYPE_TRACES => ServiceStub::Traces.new(@grpc_config.endpoint, credential, **options)
    }
    [channel, services]
  rescue StandardError
    channel&.close
    raise
  end

  def refresh_tls_files
    begin
      pems = read_tls_files
      current = fingerprints(pems)
      if current != @tls_fingerprints
        channel, services = build_services(channel_credentials(pems, rotation: true))
        old_channel = @channel
        @channel, @services, @tls_fingerprints = channel, services, current
      end
    rescue StandardError => e
      message = e.is_a?(TlsFileError) ? e.message : "could not rebuild gRPC TLS channel for #{@tls_paths.values.join(', ')} (#{e.class})"
      failure = [message, current]
      if @tls_failures.add?(failure)
        @logger.warn "#{message}; keeping the current gRPC channel and retrying the TLS files on the next export"
      end
      return
    end
    @tls_failures.clear
    return unless old_channel

    @logger.info "gRPC TLS files changed; reconnecting with the updated certificate files"
    # Let calls that already selected the old stubs finish before closing them.
    old_channel.close unless @active_exports.key?(old_channel)
  end

  def call_options
    { deadline: Time.now + @grpc_config.timeout, metadata: @metadata }
  end

  def channel_credentials(pems, rotation: false)
    return :this_channel_is_insecure unless @tls_paths

    transport = @transport_config
    ca_pem, key_pem, cert_pem = pems.values_at(:ca_path, :private_key_path, :cert_path)
    if key_pem.nil? != cert_pem.nil?
      raise TlsFileError, "gRPC TLS requires both cert_path and private_key_path for a client certificate"
    end
    # Configure-time checks stay as in 0.1.0. A rotation replaces a working
    # channel, so it also requires a parseable key that matches the certificate.
    if key_pem && (transport.private_key_passphrase || rotation)
      begin
        key = OpenSSL::PKey.read(key_pem, transport.private_key_passphrase || "")
      rescue OpenSSL::OpenSSLError, ArgumentError
        action = transport.private_key_passphrase ? "decrypt" : "read"
        raise TlsFileError, "could not #{action} gRPC TLS private_key_path '#{transport.private_key_path}'", cause: nil
      end
    end
    if key_pem && rotation
      begin
        valid_pair = OpenSSL::X509::Certificate.new(cert_pem).check_private_key(key)
      rescue OpenSSL::OpenSSLError, ArgumentError
        valid_pair = false
      end
      unless valid_pair
        raise TlsFileError, "invalid gRPC TLS client certificate/key pair '#{transport.cert_path}' and '#{transport.private_key_path}'", cause: nil
      end
    end
    key_pem = key.to_pem if key_pem && transport.private_key_passphrase
    GRPC::Core::ChannelCredentials.new(ca_pem, key_pem, cert_pem)
  end

  def read_tls_files
    @tls_paths.transform_values { |path| read_pem(path) }
  end

  def fingerprints(pems)
    pems.transform_values { |pem| Digest::SHA256.hexdigest(pem) }
  end

  def read_pem(path)
    return nil unless path

    File.binread(path)
  rescue SystemCallError, IOError
    raise TlsFileError, "could not read gRPC TLS file '#{path}'", cause: nil
  end
end
