# frozen_string_literal: true

require "fluent/plugin/opentelemetry/response"

module Fluent::Plugin::Opentelemetry::OutputResponse
  private

  def redact_headers(message)
    @headers.values.reject(&:empty?).sort_by { |value| -value.length }.reduce(message.to_s) do |text, value|
      text.gsub(value, "[REDACTED]")
    end
  end

  def warn_partial_success(response)
    partial = response&.partial_success
    return unless partial && partial.rejected_log_records > 0

    @logger.warn "OTLP logs partially accepted: rejected_log_records=#{partial.rejected_log_records}, " \
                 "error_message=#{redact_headers(partial.error_message)}"
  end
end
