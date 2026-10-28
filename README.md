# fluent-plugin-opentelemetry-radiant

A Fluentd input/output plugin for OpenTelemetry Protocol (OTLP) data. This is an
Apache-2.0 derivative of
[`fluent-plugin-opentelemetry` 0.4.0](https://github.com/fluent-plugins-nursery/fluent-plugin-opentelemetry)
by Shizuo Fujita.

The fork retains the upstream OTLP relay and both upstream input plugins, and
adds an output path that turns ordinary Fluentd records into batched OTLP logs.
It includes the input size-limit and transport robustness fixes from upstream
0.5.3, with authenticated HTTP and gRPC exports and client TLS configuration.

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

  # Read the token from the Fluentd process environment.
  headers {"Authorization":"Bearer #{ENV['OTLP_TOKEN']}"}

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

  <transport tls>
    # Omit ca_path to use the system CA roots.
    ca_path /etc/fluent/certs/collector-ca.pem
    min_version TLSv1_2
  </transport>

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
delivered again. The default buffer `chunk_limit_size` is **2 MiB**, with
`chunk_keys ["tag"]`. This leaves headroom below common 4 MiB gRPC receiver
limits because conversion can enlarge the message. It is not a strict encoded
request limit: large records and attributes can still exceed a receiver's limit.
Tune chunk sizes against the actual encoded requests and receiver settings.

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

The HTTP path sends `application/x-protobuf`. Optional gRPC support requires the
`grpc` gem to be installed separately. The transport settings below apply to all
output modes and to relay logs, metrics, and traces.

## Authentication and HTTP TLS

Top-level `headers` is a hash of string values (default `{}`). Every export uses
these headers for HTTP or their lowercase keys for gRPC metadata. Fluentd masks
the entire hash in its configuration dump. `Content-Type` and `Content-Encoding`
are reserved, case-insensitively; configured values for them are ignored.
Keep tokens in the process environment or your existing secret management system.

```conf
<match fid.**>
  @type opentelemetry_radiant
  mode records
  headers {"Authorization":"Bearer #{ENV['OTLP_TOKEN']}","X-Tenant-ID":"fid"}
  <http>
    endpoint https://collector.example.com:4318/
    compress gzip
    read_timeout 60
    write_timeout 60
    connect_timeout 60
  </http>
  <transport tls>
    ca_path /etc/fluent/certs/ca.pem
    # Set both for mutual TLS; omit both for server authentication only.
    cert_path /etc/fluent/certs/client.pem
    private_key_path /etc/fluent/certs/client-key.pem
    private_key_passphrase "#{ENV['OTLP_KEY_PASSPHRASE']}"
    min_version TLSv1_2
    max_version TLSv1_3
  </transport>
</match>
```

The HTTP endpoint is a base URL. Trailing slashes are removed before appending
`/v1/logs`, `/v1/metrics`, or `/v1/traces`. Use an `https://` URL for encryption.
`<transport tls>` supplies the CA, client certificate, key, passphrase, and TLS
version bounds to Excon. Omit `ca_path` for default system trust. `insecure true`
disables certificate verification only on this output's HTTP connections and
logs one warning at start; it does not change process-wide Excon defaults.
HTTP connections are persistent and reused across exports.

## gRPC TLS and options

```conf
<match fid.**>
  @type opentelemetry_radiant
  mode records
  headers {"Authorization":"Bearer #{ENV['OTLP_TOKEN']}"}
  <grpc>
    endpoint collector.example.com:4317
    compress gzip
    timeout 60
    keepalive_time 30
    keepalive_timeout 10
  </grpc>
  <transport tls>
    ca_path /etc/fluent/certs/ca.pem
    # Optional mutual TLS:
    cert_path /etc/fluent/certs/client.pem
    private_key_path /etc/fluent/certs/client-key.pem
  </transport>
</match>
```

The gRPC endpoint must be `host:port` (or `[IPv6]:port`), without `http://` or
`https://`. `<transport tls>` selects a secure channel. Omit `ca_path` to use
gRPC's default system roots; omit the client cert and key unless mutual TLS is
required. TLS files are read at configuration time, and unreadable files produce
a `Fluent::ConfigError` identifying the path. An encrypted client key can use
`private_key_passphrase`. Without `<transport tls>`, gRPC uses plaintext.
`insecure true` is rejected for gRPC; supply the server's CA using `ca_path`.
The HTTP `min_version` / `max_version` settings are not applied to gRPC, whose
TLS negotiation is managed by gRPC core.

**Certificate rotation.** HTTP opens new connections with the TLS files as they
are on disk. gRPC checks the configured TLS files before each send and reconnects
when their contents change. If the files cannot be read or the new credentials
are invalid, gRPC warns and keeps its current channel, then checks again on the
next send. Headers (including tokens) are read when the configuration loads, so
a token change needs a config reload. Mount Kubernetes Secrets as a directory,
not with `subPath`, because kubelet does not update `subPath` mounts.

| gRPC option | Default | Meaning |
|---|---|---|
| `compress` | `text` | `text` sends uncompressed messages; `gzip` enables gRPC gzip compression. |
| `timeout` | `60` | Deadline in seconds, refreshed for every call. |
| `keepalive_time` | `30` | Interval in seconds between gRPC keepalive pings. |
| `keepalive_timeout` | `10` | Seconds to wait for a ping acknowledgement. |

Stubs and channels are reused. Keepalive pings are permitted without active
calls; coordinate the interval with the backend's keepalive policy.

## Delivery and retries

All HTTP **2xx** responses acknowledge success. HTTP `400` is unrecoverable.
The default retryable HTTP codes are `429`, `502`, `503`, and `504`, configurable
with `<http> retryable_response_codes`. Other non-2xx responses are unrecoverable
by default; `error_response_as_unrecoverable false` logs and acknowledges those
other responses instead. Connection and DNS errors remain retryable.

For ordinary-record gRPC exports, `CANCELLED`, `DEADLINE_EXCEEDED`, `ABORTED`,
`OUT_OF_RANGE`, `UNAVAILABLE`, `DATA_LOSS`, and `RESOURCE_EXHAUSTED` raise a
retryable error for Fluentd's buffer backoff. All other gRPC error statuses raise
`Fluent::UnrecoverableError` with the code name and server details. Relay-mode
gRPC status exceptions retain upstream behavior and remain retryable through
Fluentd. Configure buffer retry policy to match operational needs.

Successful HTTP and gRPC log responses with `partial_success.rejected_log_records`
greater than zero log a warning with the count and backend error message. They
are acknowledged without retry to avoid resending accepted records. Configured
header values are redacted from these warnings and ordinary-record gRPC status
errors.

## Input plugins

The upstream inputs remain registered under their original names:

- `@type opentelemetry` receives OTLP logs, metrics, and traces over HTTP and,
  when available, gRPC.
- `@type opentelemetry_metrics` emits Fluentd internal metrics as OTLP relay
  records.

The OTLP HTTP input now limits the streamed request body and decompressed gzip
body. Configure limits inside its `<http>` section:

```conf
<source>
  @type opentelemetry
  tag opentelemetry.${type}
  <http>
    bind 0.0.0.0
    port 4318
    body_size_limit 32m
    decompression_size_limit 256m
  </http>
</source>
```

`body_size_limit` defaults to **32 MiB** and `decompression_size_limit` to
**256 MiB**. Bodies exceeding either limit return HTTP `413`; malformed or
truncated gzip returns `400`. Requests are closed on success and failure.
This includes the upstream CVE-2026-44163 / GHSA-2jc5-xhx8-qj6h fix. The gRPC
input now stops its server during Fluentd shutdown. The internal metrics input
keeps its upstream 0.4.0 behavior and `fluentd_` metric prefix; no process metrics
or `get_process_mem` dependency are added.

## Development

```sh
bundle install
bundle exec rake test
bundle exec rake build
```

## Attribution and license

Copyright notices from the upstream project are retained. See [NOTICE](NOTICE)
for the derivative-work statement and [LICENSE](LICENSE) for Apache License 2.0.
