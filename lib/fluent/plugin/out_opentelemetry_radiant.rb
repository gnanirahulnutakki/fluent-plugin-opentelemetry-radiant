# frozen_string_literal: true

# Copyright 2025- Shizuo Fujita
# Copyright 2026 Radiant Logic, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
#
# This file is based on fluent-plugin-opentelemetry 0.4.0 and was modified by
# Radiant Logic, Inc. to add ordinary-record OTLP log conversion and batching.

require "fluent/plugin/opentelemetry/constant"
require "fluent/plugin/opentelemetry/http_output_handler"
require "fluent/plugin/opentelemetry/log_record_builder"
require "fluent/plugin/output"
require "fluent/plugin_helper/server"
require "fluent/msgpack_factory"

require "json"

begin
  require "grpc"

  require "fluent/plugin/opentelemetry/grpc_output_handler"
rescue LoadError
end

module Fluent::Plugin
  class OpentelemetryRadiantOutput < Output
    class RetryableResponse < StandardError; end

    RELAY_TYPES = [
      Opentelemetry::RECORD_TYPE_LOGS,
      Opentelemetry::RECORD_TYPE_METRICS,
      Opentelemetry::RECORD_TYPE_TRACES
    ].freeze

    Fluent::Plugin.register_output("opentelemetry_radiant", self)
    Fluent::Plugin.register_output("opentelemetry", self)

    # Reuse Fluentd's transport parameters without configuring a listening server.
    include Fluent::PluginHelper::Server::ServerTransportParams

    desc "How records are handled: auto-detect relay records, relay all records, or convert all records"
    config_param :mode, :enum, list: %i[auto relay records], default: :auto
    desc "Record key used for the OTLP log body in string body format"
    config_param :body_key, :string, default: "message"
    desc "OTLP log body representation"
    config_param :body_format, :enum, list: %i[string kvlist], default: :string
    desc "Record key used for OTLP severity text and number"
    config_param :severity_key, :string, default: "severity"
    desc "Add non-body, non-severity top-level record fields as OTLP log attributes"
    config_param :attributes_from_record, :bool, default: true
    desc "Record keys omitted from OTLP log attributes"
    config_param :exclude_keys, :array, value_type: :string, default: []
    desc "Static OTLP resource attributes"
    config_param :resource_attributes, :hash, default: {}
    desc "Mapping of OTLP resource attribute names to record keys"
    config_param :resource_attributes_from_record, :hash, value_type: :string, default: {}
    desc "OTLP instrumentation scope name"
    config_param :scope_name, :string, default: "fluent-plugin-opentelemetry-radiant"

    desc "HTTP headers or gRPC metadata sent with every export"
    config_param :headers, :hash, value_type: :string, secret: true, default: {}

    config_section :buffer do
      config_set_default :chunk_keys, ["tag"]
      config_set_default :chunk_limit_size, 2 * 1024 * 1024
    end

    config_section :http, required: false, multi: false, init: false, param_name: :http_config do
      desc "The endpoint"
      config_param :endpoint, :string, default: "http://127.0.0.1:4318"
      desc "The proxy for HTTP request"
      config_param :proxy, :string, default: ENV["HTTP_PROXY"] || ENV["http_proxy"]

      desc "Raise UnrecoverableError when the response is non success, 4xx/5xx"
      config_param :error_response_as_unrecoverable, :bool, default: true
      desc "The list of retryable response code"
      config_param :retryable_response_codes, :array, value_type: :integer, default: [429, 502, 503, 504]

      desc "Compress request body"
      config_param :compress, :enum, list: %i[text gzip], default: :text

      desc "The read timeout in seconds"
      config_param :read_timeout, :integer, default: 60
      desc "The write timeout in seconds"
      config_param :write_timeout, :integer, default: 60
      desc "The connect timeout in seconds"
      config_param :connect_timeout, :integer, default: 60
    end

    config_section :grpc, required: false, multi: false, init: false, param_name: :grpc_config do
      desc "The endpoint"
      config_param :endpoint, :string, default: "127.0.0.1:4317"
      desc "Compress request body"
      config_param :compress, :enum, list: %i[text gzip], default: :text
      desc "The per-call timeout in seconds"
      config_param :timeout, :integer, default: 60
      desc "The interval in seconds to send gRPC keepalive pings"
      config_param :keepalive_time, :integer, default: 30
      desc "The timeout in seconds to wait for a keepalive acknowledgement"
      config_param :keepalive_timeout, :integer, default: 10
    end

    config_section :transport, required: false, multi: false, init: false, param_name: :transport_config do
      config_argument :protocol, :enum, list: [:tls], default: nil
    end

    def configure(conf)
      super

      if @grpc_config && !defined?(GRPC)
        raise Fluent::ConfigError, "To use gRPC feature, please install grpc gem such as 'fluent-gem install grpc'."
      end

      unless [@http_config, @grpc_config].one?
        raise Fluent::ConfigError, "Please configure either <http> or <grpc> section."
      end

      @http_handler = Opentelemetry::HttpOutputHandler.new(@http_config, @transport_config, log, @headers) if @http_config
      @grpc_handler = Opentelemetry::GrpcOutputHandler.new(@grpc_config, @transport_config, log, @headers) if @grpc_config
      @log_record_builder = Opentelemetry::LogRecordBuilder.new(
        body_key: @body_key,
        body_format: @body_format,
        severity_key: @severity_key,
        attributes_from_record: @attributes_from_record,
        exclude_keys: @exclude_keys,
        resource_attributes: @resource_attributes,
        resource_attributes_from_record: @resource_attributes_from_record,
        scope_name: @scope_name
      )
    end

    def start
      super

      if @http_config && @transport_config.protocol == :tls && @transport_config.insecure
        log.warn "OTLP/HTTP TLS certificate verification is off (insecure true)"
      end
    end

    def multi_workers_ready?
      true
    end

    def formatted_to_msgpack_binary?
      true
    end

    def format(tag, time, record)
      [time, record].to_msgpack(Fluent::MessagePackFactory.msgpack_packer).to_s
    end

    def write(chunk)
      relay_records = []
      record_events = []
      chunk.msgpack_each do |time, record|
        if relay_record?(record)
          relay_records << normalize_relay_record(record)
        else
          record_events << [time, record]
        end
      end

      request = nil
      unless record_events.empty?
        tag = chunk.metadata.tag
        raise "buffer chunk is missing tag metadata" unless tag

        request = @log_record_builder.build(tag, record_events)
      end
      handler = @grpc_handler || @http_handler
      relay_records.each { |record| handler.export(record) }
      handler.export_logs(request) if request
    end

    private

    def relay_record?(record)
      return true if @mode == :relay
      return false if @mode == :records

      type_present, type = record_value(record, "type")
      message_present, = record_value(record, "message")
      type_present && message_present && RELAY_TYPES.include?(type.to_s)
    end

    def normalize_relay_record(record)
      JSON.parse(JSON.generate(record))
    end

    def record_value(record, key)
      return [true, record[key]] if record.key?(key)

      symbol_key = key.to_sym
      return [true, record[symbol_key]] if record.key?(symbol_key)

      [false, nil]
    end
  end

  # Preserve the public class constant used by fluent-plugin-opentelemetry 0.4.0.
  OpentelemetryOutput = OpentelemetryRadiantOutput
end
