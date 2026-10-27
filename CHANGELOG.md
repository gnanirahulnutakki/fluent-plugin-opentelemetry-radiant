## [Unreleased]

- Normalize log strings to valid UTF-8 without mutating records, preventing binary or invalid bytes from dropping whole chunks.

## [0.1.0] - 2026-09-02

- Add secret-masked authentication headers for HTTP and lowercase gRPC metadata.
- Add HTTP CA and mutual TLS settings without changing global Excon defaults;
  warn once at start when HTTP certificate verification is disabled.
- Add gRPC TLS and configuration-time certificate file errors; reject URI-style
  gRPC endpoints and disabled certificate verification.
- Port upstream 0.5.3 streaming HTTP input limits (32 MiB body / 256 MiB
  decompressed), request closure, HTTP 413 and bad-gzip 400 responses
  (CVE-2026-44163 / GHSA-2jc5-xhx8-qj6h), and gRPC input shutdown.
- Reuse persistent HTTP connections, consume responses, accept all 2xx statuses,
  and normalize trailing endpoint slashes.
- Reuse gRPC stubs and apply compression, keepalive and per-call deadlines to
  both relay and ordinary-record exports.
- Classify ordinary-record gRPC status errors as retryable or unrecoverable and
  warn without retry on partial log success over HTTP or gRPC.
- Default output chunks to 2 MiB while preserving tag chunk keys.
- Add CONTENT_TYPE_PLAIN and retain CONTENT_TYPE_PAIN as a compatibility alias.
- Keep the original generated protobufs, internal metrics behavior and package
  version; no additional runtime dependencies.

- Fork fluent-plugin-opentelemetry 0.4.0 under the Radiant package name.
- Add automatic, forced-relay, and ordinary-record output modes.
- Convert ordinary records into typed, batched OTLP log export requests.
- Preserve upstream input plugins and OTLP logs, metrics, and traces relay behavior.
- Register both `opentelemetry_radiant` and `opentelemetry` output names.

## Upstream history

## [0.4.0] - 2025-10-10

- in_opentelemetry_metrics: Add plugin to support fluentd metrics export (#10)

## [0.3.0] - 2025-07-23

- in_opentelemetry: add ${type} placeholder support in tag parameter (#8)
- in_opentelemetry: use String for record keys (#6)

## [0.2.0] - 2025-06-26

- Make gRPC sending and receiving optional (#4)
  - To use gRPC sending and receiving, you need to install `grpc` gem manually.

## [0.1.0] - 2025-03-31

- Initial release
