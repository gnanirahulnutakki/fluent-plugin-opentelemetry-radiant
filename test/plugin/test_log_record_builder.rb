# frozen_string_literal: true

# Copyright 2026 Radiant Logic, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

require "helper"
require "fluent/plugin/opentelemetry/log_record_builder"

class LogRecordBuilderTest < Test::Unit::TestCase
  STRING_CASES = {
    "binary cafe" => ["caf\xC3\xA9".b, "café"],
    "binary non-breaking space" => ["a\xC2\xA0b".b, "a\u00A0b"],
    "invalid binary byte" => ["bad\xFFbyte".b, "bad\uFFFDbyte"],
    "truncated binary sequence" => ["bad\xC2".b, "bad\uFFFD"],
    "invalid UTF-8" => ["bad\xFFbyte", "bad\uFFFDbyte"],
    "Latin-1" => ["caf\xE9".dup.force_encoding(Encoding::ISO_8859_1), "café"],
    "undefined Windows-1252 byte" => ["bad\x81byte".dup.force_encoding(Encoding::Windows_1252), "bad\uFFFDbyte"],
    "UTF-16LE" => ["café".encode(Encoding::UTF_16LE), "café"],
    "invalid UTF-16LE" => ["a\x00\xFF".dup.force_encoding(Encoding::UTF_16LE), "a\uFFFD"]
  }.freeze

  def build(record, tag: "fid.access", **options)
    builder = Fluent::Plugin::Opentelemetry::LogRecordBuilder.new(**{
      body_key: "message", body_format: :string, severity_key: "severity",
      attributes_from_record: true, exclude_keys: [], resource_attributes: {},
      resource_attributes_from_record: {}, scope_name: "test", clock: -> { 123 }
    }.merge(options))
    request = builder.build(tag, [[123, record]])
    request.class.decode(request.to_proto).resource_logs.fetch(0)
  end

  def attributes(values)
    values.to_h { |attribute| [attribute.key, attribute.value] }
  end

  data(STRING_CASES)
  def test_string_body_is_valid_utf8_without_mutating_the_record(data)
    input, expected = data
    original_bytes = input.bytes
    original_encoding = input.encoding
    record = { "message" => input.freeze }.freeze

    resource_logs = build(record)
    log_record = resource_logs.scope_logs.first.log_records.first

    assert_equal expected, log_record.body.string_value
    assert_equal Encoding::UTF_8, log_record.body.string_value.encoding
    assert_same input, record.fetch("message")
    assert_equal original_bytes, input.bytes
    assert_equal original_encoding, input.encoding
  end

  data(STRING_CASES)
  def test_attribute_keys_and_values_are_normalized_in_nested_hashes_and_arrays(data)
    input, expected = data
    record = {
      "message" => "body", input => input,
      "nested" => { input => [input, { input => input }] }
    }

    resource_logs = build(record)
    values = attributes(resource_logs.scope_logs.first.log_records.first.attributes)
    nested = attributes(values.fetch("nested").kvlist_value.values)
    array = nested.fetch(expected).array_value.values

    assert_equal expected, values.fetch(expected).string_value
    assert_equal expected, array.fetch(0).string_value
    assert_equal expected, attributes(array.fetch(1).kvlist_value.values).fetch(expected).string_value
  end

  data(STRING_CASES)
  def test_resource_attribute_keys_and_values_are_normalized(data)
    input, expected = data
    resource_logs = build(
      { "message" => "body", "host" => { input => [input] } },
      resource_attributes: { input => input },
      resource_attributes_from_record: { "host.name" => "host" }
    )
    values = attributes(resource_logs.resource.attributes)
    host = attributes(values.fetch("host.name").kvlist_value.values)

    assert_equal expected, values.fetch(expected).string_value
    assert_equal expected, host.fetch(expected).array_value.values.first.string_value
  end

  data(STRING_CASES)
  def test_json_fallback_normalizes_nested_keys_and_values_without_mutating_them(data)
    input, expected = data
    original_bytes = input.bytes
    original_encoding = input.encoding
    record = { input => [input.freeze, { "nested" => input }.freeze], "count" => 2, "ok" => true, "nil" => nil }.freeze

    resource_logs = build(record)
    body = resource_logs.scope_logs.first.log_records.first.body.string_value

    assert_equal({ expected => [expected, { "nested" => expected }], "count" => 2, "ok" => true, "nil" => nil }, JSON.parse(body))
    assert_equal original_bytes, input.bytes
    assert_equal original_encoding, input.encoding
  end

  data(STRING_CASES)
  def test_kvlist_body_normalizes_nested_keys_and_values(data)
    input, expected = data
    resource_logs = build({ input => { "values" => [input] } }, body_format: :kvlist)
    body = resource_logs.scope_logs.first.log_records.first.body.kvlist_value
    nested = attributes(attributes(body.values).fetch(expected).kvlist_value.values)

    assert_equal expected, nested.fetch("values").array_value.values.first.string_value
  end

  data(STRING_CASES)
  def test_tag_severity_and_scope_name_are_normalized(data)
    input, expected = data
    resource_logs = build({ "message" => "body", "severity" => input }, tag: input, scope_name: input)
    scope_logs = resource_logs.scope_logs.first
    log_record = scope_logs.log_records.first

    assert_equal expected, scope_logs.scope.name
    assert_equal expected, log_record.severity_text
    assert_equal :SEVERITY_NUMBER_UNSPECIFIED, log_record.severity_number
    assert_equal expected, attributes(log_record.attributes).fetch("fluent.tag").string_value
  end

  def test_stringified_values_are_normalized
    value = Object.new
    value.define_singleton_method(:to_s) { "bad\xFFbyte".b }

    resource_logs = build({ "message" => value, "value" => value })
    log_record = resource_logs.scope_logs.first.log_records.first

    assert_equal "bad\uFFFDbyte", log_record.body.string_value
    assert_equal "bad\uFFFDbyte", attributes(log_record.attributes).fetch("value").string_value
  end

  def test_json_fallback_preserves_distinct_string_and_symbol_keys
    record = { "field" => "string key", field: "symbol key" }
    expected = begin
      JSON.generate(record)
    rescue JSON::GeneratorError => e
      e
    end

    if expected.is_a?(JSON::GeneratorError)
      assert_raise(JSON::GeneratorError) { build(record) }
    else
      resource_logs = build(record)
      assert_equal expected, resource_logs.scope_logs.first.log_records.first.body.string_value
    end
  end
end
