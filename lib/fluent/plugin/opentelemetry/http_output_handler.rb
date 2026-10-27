# frozen_string_literal: true

# Copyright 2025- Shizuo Fujita
# Copyright 2026 Radiant Logic, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
#
# Modified by Radiant Logic, Inc. to export prepared OTLP logs requests while
# retaining the upstream relay and response-handling paths.

require "fluent/plugin/opentelemetry/constant"
require "fluent/plugin/opentelemetry/request"
require "fluent/plugin/opentelemetry/output_response"

require "excon"
require "google/protobuf"
require "stringio"
require "zlib"

class Fluent::Plugin::Opentelemetry::HttpOutputHandler
  include Fluent::Plugin::Opentelemetry::OutputResponse

  def initialize(http_config, transport_config, logger, headers = {})
    @http_config = http_config
    @logger = logger
    @headers = headers
    @endpoint = http_config.endpoint.sub(%r{/+\z}, "")

    tls_settings = {}
    if transport_config.protocol == :tls
      tls_settings[:ssl_ca_file] = transport_config.ca_path if transport_config.ca_path
      tls_settings[:client_cert] = transport_config.cert_path
      tls_settings[:client_key] = transport_config.private_key_path
      tls_settings[:client_key_pass] = transport_config.private_key_passphrase
      tls_settings[:ssl_min_version] = Fluent::Plugin::Opentelemetry::TLS_VERSIONS_MAP[transport_config.min_version]
      tls_settings[:ssl_max_version] = Fluent::Plugin::Opentelemetry::TLS_VERSIONS_MAP[transport_config.max_version]
      tls_settings[:ssl_verify_peer] = !transport_config.insecure
    end

    timeout_settings = {
      read_timeout: http_config.read_timeout,
      write_timeout: http_config.write_timeout,
      connect_timeout: http_config.connect_timeout
    }
    @connections = {
      Fluent::Plugin::Opentelemetry::RECORD_TYPE_LOGS => http_logs_endpoint,
      Fluent::Plugin::Opentelemetry::RECORD_TYPE_METRICS => http_metrics_endpoint,
      Fluent::Plugin::Opentelemetry::RECORD_TYPE_TRACES => http_traces_endpoint
    }.transform_values do |uri|
      Excon.new(uri, proxy: http_config.proxy, persistent: true, **tls_settings, **timeout_settings)
    end
  end

  def export(record)
    uri, headers, body = get_post_data(record)
    post(uri, @connections.fetch(record["type"]), headers: headers, body: body,
         logs: record["type"] == Fluent::Plugin::Opentelemetry::RECORD_TYPE_LOGS)
  end

  def export_logs(request)
    headers, body = prepare_body(request.to_proto)
    post(http_logs_endpoint, @connections.fetch(Fluent::Plugin::Opentelemetry::RECORD_TYPE_LOGS),
         headers: headers, body: body, logs: true)
  end

  private

  def post(uri, connection, **options)
    logs = options.delete(:logs)
    response = connection.post(**options)
    # Read every response, including errors, before reusing the connection.
    body = response.body

    if (200...300).cover?(response.status)
      check_logs_response(body, response.headers) if logs && body && !body.empty?
      return
    end

    if response.status == 400
      # The client MUST NOT retry HTTP 400 Bad Request.
      raise Fluent::UnrecoverableError, "got unrecoverable error response from '#{uri}', response code is #{response.status}"
    end

    if @http_config.retryable_response_codes&.include?(response.status)
      raise Fluent::Plugin::OpentelemetryOutput::RetryableResponse, "got retryable error response from '#{uri}', response code is #{response.status}"
    end
    if @http_config.error_response_as_unrecoverable
      raise Fluent::UnrecoverableError, "got unrecoverable error response from '#{uri}', response code is #{response.status}"
    else
      @logger.error "got error response from '#{uri}', response code is #{response.status}"
    end
  rescue Excon::Error => e
    message = redact_headers(e.message)
    raise if message == e.message

    # Fluentd logs retry errors; a backend or proxy may echo request headers.
    raise Fluent::Plugin::OpentelemetryOutput::RetryableResponse, message, cause: nil
  end

  def check_logs_response(body, headers)
    content_type = headers.find { |key, _| key.downcase == "content-type" }&.last.to_s.split(";").first
    response_class = Opentelemetry::Proto::Collector::Logs::V1::ExportLogsServiceResponse
    response = if content_type == Fluent::Plugin::Opentelemetry::CONTENT_TYPE_JSON
                 response_class.decode_json(body)
               else
                 response_class.decode(body)
               end
    warn_partial_success(response)
  rescue Google::Protobuf::ParseError
    # A successful HTTP status acknowledges delivery even if its body is invalid.
    @logger.warn "Could not decode successful OTLP logs response; delivery will not be retried"
  end

  def http_logs_endpoint
    "#{@endpoint}/v1/logs"
  end

  def http_metrics_endpoint
    "#{@endpoint}/v1/metrics"
  end

  def http_traces_endpoint
    "#{@endpoint}/v1/traces"
  end

  def get_post_data(record)
    uri, request_class = case record["type"]
                         when Fluent::Plugin::Opentelemetry::RECORD_TYPE_LOGS
                           [http_logs_endpoint, Fluent::Plugin::Opentelemetry::Request::Logs]
                         when Fluent::Plugin::Opentelemetry::RECORD_TYPE_METRICS
                           [http_metrics_endpoint, Fluent::Plugin::Opentelemetry::Request::Metrics]
                         when Fluent::Plugin::Opentelemetry::RECORD_TYPE_TRACES
                           [http_traces_endpoint, Fluent::Plugin::Opentelemetry::Request::Traces]
                         else
                           raise Fluent::UnrecoverableError, "got unknown record type '#{record['type']}'"
                         end
    headers, body = prepare_body(request_class.new(record["message"]).body)
    [uri, headers, body]
  rescue Google::Protobuf::ParseError => e
    raise Fluent::UnrecoverableError, e.message
  end

  def prepare_body(body)
    # Header names are case-insensitive. Neither reserved header is user-settable,
    # including Content-Encoding when compression is disabled.
    headers = @headers.reject { |key, _| %w[content-type content-encoding].include?(key.downcase) }
    headers[Fluent::Plugin::Opentelemetry::CONTENT_TYPE] = Fluent::Plugin::Opentelemetry::CONTENT_TYPE_PROTOBUF
    if @http_config.compress == :gzip
      headers[Fluent::Plugin::Opentelemetry::CONTENT_ENCODING] = Fluent::Plugin::Opentelemetry::CONTENT_ENCODING_GZIP
      gz = Zlib::GzipWriter.new(StringIO.new)
      gz << body
      body = gz.close.string
    end
    [headers, body]
  end
end
