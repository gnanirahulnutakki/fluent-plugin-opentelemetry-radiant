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
require "google/protobuf"

class Fluent::Plugin::Opentelemetry::GrpcOutputHandler
  class ServiceStub
    class Logs
      def initialize(host, creds, **kw)
        @stub = Opentelemetry::Proto::Collector::Logs::V1::LogsService::Stub.new(host, creds, **kw)
      end

      def export(json)
        message = Opentelemetry::Proto::Collector::Logs::V1::ExportLogsServiceRequest.decode_json(json)
        @stub.export(message)
      end

      def export_request(message)
        @stub.export(message)
      end
    end

    class Metrics
      def initialize(host, creds, **kw)
        @stub = Opentelemetry::Proto::Collector::Metrics::V1::MetricsService::Stub.new(host, creds, **kw)
      end

      def export(json)
        message = Opentelemetry::Proto::Collector::Metrics::V1::ExportMetricsServiceRequest.decode_json(json)
        @stub.export(message)
      end
    end

    class Traces
      def initialize(host, creds, **kw)
        @stub = Opentelemetry::Proto::Collector::Trace::V1::TraceService::Stub.new(host, creds, **kw)
      end

      def export(json)
        message = Opentelemetry::Proto::Collector::Trace::V1::ExportTraceServiceRequest.decode_json(json)
        @stub.export(message)
      end
    end
  end

  def initialize(grpc_config, transport_config, logger)
    @grpc_config = grpc_config
    @transport_config = transport_config
    @logger = logger
  end

  def export(record)
    msg = record["message"]

    credential = :this_channel_is_insecure

    case record["type"]
    when Fluent::Plugin::Opentelemetry::RECORD_TYPE_LOGS
      service = ServiceStub::Logs.new(@grpc_config.endpoint, credential)
    when Fluent::Plugin::Opentelemetry::RECORD_TYPE_METRICS
      service = ServiceStub::Metrics.new(@grpc_config.endpoint, credential)
    when Fluent::Plugin::Opentelemetry::RECORD_TYPE_TRACES
      service = ServiceStub::Traces.new(@grpc_config.endpoint, credential)
    end

    begin
      service.export(msg)
    rescue Google::Protobuf::ParseError => e
      # The message format does not comply with the OpenTelemetry protocol.
      raise ::Fluent::UnrecoverableError, e.message
    end
  end

  def export_logs(request)
    logs_service.export_request(request)
  end

  private

  def logs_service
    credential = :this_channel_is_insecure
    ServiceStub::Logs.new(@grpc_config.endpoint, credential)
  end
end
