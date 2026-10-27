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

class Fluent::Plugin::Opentelemetry::GrpcOutputHandler
  include Fluent::Plugin::Opentelemetry::OutputResponse

  RETRYABLE_CODES = %i[CANCELLED DEADLINE_EXCEEDED ABORTED OUT_OF_RANGE UNAVAILABLE DATA_LOSS RESOURCE_EXHAUSTED].map do |name|
    GRPC::Core::StatusCodes.const_get(name)
  end.freeze
  CODE_NAMES = GRPC::Core::StatusCodes.constants.to_h do |name|
    [GRPC::Core::StatusCodes.const_get(name), name.to_s]
  end.freeze

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

    credential = channel_credentials(transport_config)
    channel_args = {}
    if grpc_config.compress == :gzip
      channel_args = GRPC::Core::CompressionOptions.new(default_algorithm: :gzip).to_channel_arg_hash
    end
    channel_args["grpc.keepalive_time_ms"] = grpc_config.keepalive_time * 1000
    channel_args["grpc.keepalive_timeout_ms"] = grpc_config.keepalive_timeout * 1000
    channel_args["grpc.keepalive_permit_without_calls"] = 1
    @services = {
      Fluent::Plugin::Opentelemetry::RECORD_TYPE_LOGS => ServiceStub::Logs.new(grpc_config.endpoint, credential, channel_args: channel_args),
      Fluent::Plugin::Opentelemetry::RECORD_TYPE_METRICS => ServiceStub::Metrics.new(grpc_config.endpoint, credential, channel_args: channel_args),
      Fluent::Plugin::Opentelemetry::RECORD_TYPE_TRACES => ServiceStub::Traces.new(grpc_config.endpoint, credential, channel_args: channel_args)
    }
  end

  def export(record)
    service = @services[record["type"]]
    raise Fluent::UnrecoverableError, "got unknown record type '#{record['type']}'" unless service

    response = service.export(record["message"], **call_options)
    warn_partial_success(response) if record["type"] == Fluent::Plugin::Opentelemetry::RECORD_TYPE_LOGS
  rescue Google::Protobuf::ParseError => e
    raise Fluent::UnrecoverableError, e.message
  rescue GRPC::BadStatus => e
    # Preserve upstream relay retry behavior without exposing echoed credentials.
    raise GRPC::BadStatus.new_status_exception(e.code, redact_headers(e.details)), cause: nil
  end

  def export_logs(request)
    response = logs_service.export_request(request, **call_options)
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

  def call_options
    { deadline: Time.now + @grpc_config.timeout, metadata: @metadata }
  end

  def channel_credentials(transport)
    return :this_channel_is_insecure unless transport&.protocol == :tls

    ca_pem = read_pem(transport.ca_path)
    key_pem = read_pem(transport.private_key_path)
    cert_pem = read_pem(transport.cert_path)
    if key_pem.nil? != cert_pem.nil?
      raise Fluent::ConfigError, "gRPC TLS requires both cert_path and private_key_path for a client certificate"
    end
    if key_pem && transport.private_key_passphrase
      begin
        key_pem = OpenSSL::PKey.read(key_pem, transport.private_key_passphrase).to_pem
      rescue OpenSSL::OpenSSLError, ArgumentError
        raise Fluent::ConfigError, "could not decrypt gRPC TLS private_key_path '#{transport.private_key_path}'", cause: nil
      end
    end
    GRPC::Core::ChannelCredentials.new(ca_pem, key_pem, cert_pem)
  end

  def read_pem(path)
    return nil unless path

    File.read(path)
  rescue SystemCallError, IOError
    raise Fluent::ConfigError, "could not read gRPC TLS file '#{path}'", cause: nil
  end
end
