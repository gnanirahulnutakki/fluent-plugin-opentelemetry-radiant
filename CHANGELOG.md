## [Unreleased]

## [0.1.0] - 2026-09-02

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
