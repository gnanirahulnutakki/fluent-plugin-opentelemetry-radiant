# fluent-plugin-opentelemetry-radiant

A Fluentd input/output plugin for OpenTelemetry Protocol (OTLP) data. This is an
Apache-2.0 derivative of
[`fluent-plugin-opentelemetry` 0.4.0](https://github.com/fluent-plugins-nursery/fluent-plugin-opentelemetry)
by Shizuo Fujita.

The fork retains the upstream OTLP relay and both upstream input plugins, and
adds an output path that turns ordinary Fluentd records into batched OTLP logs.

> [!IMPORTANT]
> Do not install this gem alongside `fluent-plugin-opentelemetry`. This gem
> replaces it and intentionally ships the same input names, compatibility output
> name, and generated protobuf descriptors. Co-installation can cause duplicate
> Fluentd registry entries or duplicate protobuf descriptor errors.

## Installation

```sh
fluent-gem install fluent-plugin-opentelemetry-radiant
```

## Output modes

The output is registered as both `opentelemetry_radiant` and `opentelemetry`.

| `mode` | Behavior |
|---|---|
| `auto` (default) | Relay records with a supported OTLP `type` and a `message`; convert every other record. Mixed chunks are partitioned. |
| `relay` | Send every record through the upstream OTLP relay path. |
| `records` | Convert every record into an OTLP `LogRecord`. |

Supported relay types remain `opentelemetry_logs`, `opentelemetry_metrics`, and
`opentelemetry_traces`.

## Ordinary-record configuration

```conf
<match fid.**>
  @type opentelemetry_radiant
  mode records

  body_key message
  body_format string
  severity_key severity
  attributes_from_record true
  exclude_keys hostname,clustername

  resource_attributes {"service.name":"fid"}
  resource_attributes_from_record {"host.name":"hostname","k8s.cluster.name":"clustername"}
  scope_name fluent-plugin-opentelemetry-radiant

  <http>
    endpoint https://otel-collector.example.com
    compress text
    read_timeout 60
    write_timeout 60
    connect_timeout 60
  </http>

  <buffer tag>
    @type file
    path /var/log/fluent/otel-buffer
    flush_interval 5s
    retry_forever true
  </buffer>
</match>
```

For `body_format string`, a present `body_key` value is converted with Ruby's
`to_s`; when the key is absent, the complete record is JSON-encoded. For
`body_format kvlist`, the complete record becomes an OTLP `KeyValueList` body.

With `attributes_from_record true`, fields other than `body_key`, `severity_key`,
and `exclude_keys` become log attributes. Strings, signed 64-bit integers,
floats, and booleans use their matching OTLP `AnyValue` fields. Hashes and arrays
are recursively represented as `kvlist_value` and `array_value`. Because OTLP
has no null `AnyValue`, `nil` is represented as the string `"null"`; integers
outside the signed 64-bit OTLP range are represented losslessly as strings.
`fluent.tag` is always added and cannot be excluded.

Static `resource_attributes` are overlaid by values selected through
`resource_attributes_from_record`; mapped values come from the first converted
record in the chunk. A missing mapped record key is ignored.

Severity matching is case-insensitive: TRACE=1, DEBUG=5, INFO=9, WARN=13,
ERROR=17, and FATAL=21. Unknown text uses OTLP's unspecified number (0). If the
severity key is absent, both fields remain unset/defaulted.

Converted records in one Fluentd chunk are sent in one
`ExportLogsServiceRequest`. Delivery is at least once: if any relay or converted
export fails, Fluentd retries the chunk and a previously accepted request can be
delivered again.

## Relay configuration

This remains compatible with the output emitted by the upstream
`opentelemetry` and `opentelemetry_metrics` inputs:

```conf
<match opentelemetry.**>
  @type opentelemetry
  mode relay

  <http>
    endpoint http://127.0.0.1:4318
  </http>
</match>
```

The HTTP path sends `application/x-protobuf` and preserves upstream compression,
timeout, retryable-response, and unrecoverable-response behavior. Optional gRPC
support still requires the `grpc` gem to be installed separately.

## Input plugins

The upstream inputs remain registered under their original names:

- `@type opentelemetry` receives OTLP logs, metrics, and traces over HTTP and,
  when available, gRPC.
- `@type opentelemetry_metrics` emits Fluentd internal metrics as OTLP relay
  records.

Their configuration and behavior are unchanged from upstream 0.4.0.

## Development

```sh
bundle install
bundle exec rake test
bundle exec rake build
```

## Attribution and license

Copyright notices from the upstream project are retained. See [NOTICE](NOTICE)
for the derivative-work statement and [LICENSE](LICENSE) for Apache License 2.0.
