# frozen_string_literal: true

# Copyright 2025- Shizuo Fujita
# Copyright 2026 Radiant Logic, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
#
# This file was added by Radiant Logic, Inc. to convert ordinary Fluentd
# records into OpenTelemetry Protocol log export requests.

require "fluent/plugin/opentelemetry/constant"
require "opentelemetry/proto/collector/logs/v1/logs_service_pb"

require "json"

class Fluent::Plugin::Opentelemetry::LogRecordBuilder
  SEVERITY_NUMBERS = {
    "TRACE" => 1,
    "DEBUG" => 5,
    "INFO" => 9,
    "WARN" => 13,
    "ERROR" => 17,
    "FATAL" => 21
  }.freeze

  INT64_RANGE = (-(2**63)..((2**63) - 1)).freeze

  def initialize(body_key:, body_format:, severity_key:, attributes_from_record:, exclude_keys:,
                 resource_attributes:, resource_attributes_from_record:, scope_name:, clock: nil)
    @body_key = body_key
    @body_format = body_format
    @severity_key = severity_key
    @attributes_from_record = attributes_from_record
    @exclude_keys = exclude_keys.map(&:to_s).freeze
    @resource_attributes = resource_attributes
    @resource_attributes_from_record = resource_attributes_from_record
    @scope_name = scope_name
    @clock = clock || method(:current_time_unix_nano)
  end

  def build(tag, events)
    raise ArgumentError, "events must not be empty" if events.empty?

    observed_time_unix_nano = @clock.call
    log_records = events.map do |time, record|
      build_log_record(tag, time, record, observed_time_unix_nano)
    end

    collector_logs_v1::ExportLogsServiceRequest.new(
      resource_logs: [
        logs_v1::ResourceLogs.new(
          resource: resource_v1::Resource.new(attributes: resource_attributes(events.first[1])),
          scope_logs: [
            logs_v1::ScopeLogs.new(
              scope: common_v1::InstrumentationScope.new(name: utf8_string(@scope_name)),
              log_records: log_records
            )
          ]
        )
      ]
    )
  end

  private

  def build_log_record(tag, time, record, observed_time_unix_nano)
    values = {
      time_unix_nano: event_time_unix_nano(time),
      observed_time_unix_nano: observed_time_unix_nano,
      body: body(record),
      attributes: log_attributes(tag, record)
    }

    severity_present, severity = record_value(record, @severity_key)
    if severity_present
      values[:severity_text] = utf8_string(severity.to_s)
      values[:severity_number] = SEVERITY_NUMBERS.fetch(values[:severity_text].upcase, 0)
    end

    logs_v1::LogRecord.new(**values)
  end

  def body(record)
    if @body_format == :kvlist
      return common_v1::AnyValue.new(
        kvlist_value: common_v1::KeyValueList.new(values: key_values(record))
      )
    end

    body_present, body_value = record_value(record, @body_key)
    text = body_present ? body_value.to_s : JSON.generate(normalize_json_strings(record))
    common_v1::AnyValue.new(string_value: utf8_string(text))
  end

  def log_attributes(tag, record)
    attributes = {}
    if @attributes_from_record
      record.each do |key, value|
        attribute_name = key.to_s
        next if attribute_name == @body_key
        next if attribute_name == @severity_key
        next if @exclude_keys.include?(attribute_name)
        next if attribute_name == "fluent.tag"

        attributes[attribute_name] = value
      end
    end
    attributes["fluent.tag"] = tag
    key_values(attributes)
  end

  def resource_attributes(first_record)
    attributes = @resource_attributes.each_with_object({}) do |(key, value), result|
      result[key.to_s] = value
    end

    @resource_attributes_from_record.each do |attribute_name, record_key|
      present, value = record_value(first_record, record_key.to_s)
      attributes[attribute_name.to_s] = value if present
    end

    key_values(attributes)
  end

  def key_values(values)
    values.map do |key, value|
      common_v1::KeyValue.new(key: utf8_string(key.to_s), value: any_value(value))
    end
  end

  def any_value(value)
    case value
    when String
      common_v1::AnyValue.new(string_value: utf8_string(value))
    when Integer
      if INT64_RANGE.cover?(value)
        common_v1::AnyValue.new(int_value: value)
      else
        common_v1::AnyValue.new(string_value: utf8_string(value.to_s))
      end
    when Float
      common_v1::AnyValue.new(double_value: value)
    when TrueClass, FalseClass
      common_v1::AnyValue.new(bool_value: value)
    when Hash
      common_v1::AnyValue.new(
        kvlist_value: common_v1::KeyValueList.new(values: key_values(value))
      )
    when Array
      common_v1::AnyValue.new(
        array_value: common_v1::ArrayValue.new(values: value.map { |item| any_value(item) })
      )
    when NilClass
      common_v1::AnyValue.new(string_value: "null")
    else
      common_v1::AnyValue.new(string_value: utf8_string(value.to_s))
    end
  end

  def utf8_string(string)
    return string if string.encoding == Encoding::UTF_8 && string.valid_encoding?

    string = if string.encoding == Encoding::ASCII_8BIT
               string.dup.force_encoding(Encoding::UTF_8)
             elsif string.encoding != Encoding::UTF_8
               string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
             else
               string
             end
    string.scrub("\uFFFD")
  end

  def normalize_json_strings(value)
    case value
    when String
      utf8_string(value)
    when Hash
      value.each_with_object({}) do |(key, item), result|
        normalized_key = key.is_a?(String) ? utf8_string(key) : key
        result[normalized_key] = normalize_json_strings(item)
      end
    when Array
      value.map { |item| normalize_json_strings(item) }
    else
      value
    end
  end

  def record_value(record, key)
    return [true, record[key]] if record.key?(key)

    symbol_key = key.to_sym
    return [true, record[symbol_key]] if record.key?(symbol_key)

    [false, nil]
  end

  def event_time_unix_nano(time)
    if time.is_a?(Time)
      (time.to_i * 1_000_000_000) + time.nsec
    elsif time.respond_to?(:sec) && time.respond_to?(:nsec)
      (time.sec * 1_000_000_000) + time.nsec
    else
      time.to_i * 1_000_000_000
    end
  end

  def current_time_unix_nano
    now = Time.now
    (now.to_i * 1_000_000_000) + now.nsec
  end

  def collector_logs_v1
    ::Opentelemetry::Proto::Collector::Logs::V1
  end

  def logs_v1
    ::Opentelemetry::Proto::Logs::V1
  end

  def common_v1
    ::Opentelemetry::Proto::Common::V1
  end

  def resource_v1
    ::Opentelemetry::Proto::Resource::V1
  end
end
