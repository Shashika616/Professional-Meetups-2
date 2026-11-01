# Claude Code prompt 29D: analytics module and OpenTelemetry (backend)

Read first: `docs/plans/29-credits-billing-analytics.md` (sections 1, 2, 4.1 to 4.4, 5, 7), `docs/decisions/adr-011-analytics-and-telemetry.md`, `backend/internal/platform/{metrics,logging,outbox}`, `backend/internal/gateway/handlers/observability.go`, `backend/internal/gateway/monolithclient/monolithclient.go`, `backend/cmd/{gateway,monolith}/main.go`, `backend/go.mod`.

## Goal

A best-effort, privacy-safe event pipeline (app and server events into Postgres and an archive) and OpenTelemetry tracing, metrics and event logs that can be pointed at Kibana, Prometheus or Grafana later by configuration only.

## Hard rules

1. Working tree only, test fixtures untouched, module boundaries (schema `analytics`, own sqlc entry, `config/`, proto `analytics/v1`, gRPC server), tests first.
2. Privacy: never store names, emails, phones, free text, meetup titles or labels, exact coordinates, IP addresses, receipts, or raw user ids. `user_key` = HMAC-SHA256(user id, `ANALYTICS_USER_KEY_SECRET` from Secret Manager). Unknown events and attributes are dropped and counted, never stored.
3. Analytics must never slow down or fail a user request: bounded buffers, drop and count when full, no synchronous export on the request path.
4. Billing correctness never depends on analytics.
5. Exporter default is `none`; adding an exporter is configuration (`OTEL_EXPORTER=none|stdout|otlp`, `OTEL_EXPORTER_OTLP_ENDPOINT`, standard `OTEL_*` env vars honoured).
6. Pin new dependencies to exact versions that are at least two weeks old, and run `govulncheck` on the result.

## Work, in order

1. **OpenTelemetry platform** (`internal/platform/telemetry`): tracer, meter and logger providers with resource attributes (`service.name`, `service.version`, `deployment.environment`), graceful shutdown flush. `otelhttp` on the gateway, `otelgrpc` client and server (W3C trace context replaces the lost request id; keep `X-Request-ID` in logs and add `trace_id`), pgx tracer, spans around store calls and outbox processing.
2. **Metrics**: expose the monolith's Prometheus registry through the gateway's token-protected `/metrics` (a gRPC call or a localhost-only listener; document the choice), add the business counters in plan 4.4 with low-cardinality labels only.
3. **Registry** `internal/modules/analytics/registry/events.yaml` (embedded): every event in plan 4.1 with schema version, allowed attributes and types; a generator (`go generate`) that writes `frontend/lib/core/analytics/event_names.g.dart` so client and server share one source.
4. **Schema**: migrations for `analytics.events` (range-partitioned by `received_at` day, BRIN and `(event_name, received_at)` indexes), `analytics.partitions` maintenance state, `analytics.opt_outs`, daily aggregate tables (`daily_screen_stats`, `daily_feature_stats`, `daily_funnel_stats`, `daily_session_stats`, `daily_error_stats`, `daily_credit_stats`, `user_first_seen` for cohorts), `analytics.report_runs`.
5. **Ingest** `POST /v1/analytics/events` (authenticated or anonymous with `install_id`): gzip, 50 events and 64 KB per batch, 30 batches per minute per user or install, envelope and registry validation, clock-skew rejection, dedupe by `event_id`, bounded buffer flushed by `COPY` (every 2 seconds or 500 events, and on shutdown), each accepted event also emitted as an OTel log record. Respect `analytics.enabled` and opt-outs.
6. **Server domain events**: subscribe to billing and meetup outbox events (not the lossy bus) and record `meetup_created`, `join_requested`, `request_accepted`, `meetup_completed`, `credits_*`, `purchase_verified`, `subscription_changed`.
7. **Sweeps** (ops list and `deploy_manifest_test.go`): create partitions three days ahead; nightly aggregation of the previous day (idempotent by date); archive the oldest partition as gzip NDJSON to Cloud Storage (`ANALYTICS_ARCHIVE_BUCKET`, prefix `analytics/raw/YYYY/MM/DD.ndjson.gz`, write through the Cloud Run service account; skip with a warning when unset) before dropping partitions older than `ANALYTICS_RAW_RETENTION_DAYS` (default 14).
8. **Deletion and opt-out**: on user deletion, delete that user's events and per-user aggregate rows by `user_key`; `PUT /v1/analytics/consent` stores opt-out server-side.
9. **Docs**: `docs/api/analytics.md` (envelope, every event, limits), `docs/observability.md` (how to run an OpenTelemetry Collector to Elasticsearch and Kibana, Prometheus and Grafana; nothing deployed), privacy notes for the policy update.

## Tests that must exist

- Registry: unknown event dropped, unknown attribute dropped, wrong type dropped, string over 100 characters dropped, all counted.
- Ingest limits: 51 events, 65 KB, 31st batch in a minute, skewed timestamps.
- Duplicate `event_id` stored once.
- Buffer full drops without blocking the handler (benchmark-style test with a stalled writer).
- Opt-out and deletion remove data; a raw user id never appears in any stored row (scan test).
- Partition creation, aggregation and drop are idempotent; archive skipped cleanly when no bucket.
- Trace context propagates gateway → monolith (one trace id across both in a test exporter).
- Load: a script `backend/scripts/analytics-load.sh` sends 200 batches per second for 60 seconds at local Postgres; record p95 latency and drop count in the report.

## Finish

`go vet ./...`, `gofmt`, `go test -race ./...`, `govulncheck ./...`. Report at `docs/plans/29D-completion-report.md`. Do not start 29E.
