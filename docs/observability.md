# Observability (plan 29D)

What the gateway and the monolith emit, how to read it today on the free tier,
and how to send it to Elasticsearch and Kibana, or Prometheus and Grafana, later.
Moving to a backend is configuration only; no code changes. Nothing on this page is
deployed by this plan.

## What is emitted

| Signal | Where it comes from | Default |
|---|---|---|
| Logs | `slog` JSON on stderr. Every request line carries `request_id` and, now, `trace_id` | Cloud Logging reads stderr; nothing to configure |
| Traces | OpenTelemetry SDK (`internal/platform/telemetry`): `otelhttp` on the gateway (`/healthz` and `/readyz` excluded), `otelgrpc` on both sides of the gateway → monolith call, a pgx tracer (one span per query, named by operation and sqlc query name, never the arguments), and spans around each outbox delivery (`outbox deliver`) and store call (`store verify`, `store finish`) | Created and sampled, not exported (`OTEL_EXPORTER=none`) |
| Metrics | The existing Prometheus registries, one per process | Scraped from the gateway, behind a token (below) |
| Event logs | Each analytics event written to Postgres is also an OTel log record (`event.name`, `event.id`, `event.source`, plus `app.screen.name` and `app.flow.id` when set), emitted by the flusher goroutine, never on a request | Not exported (`none`) |

The W3C `traceparent` header carries the trace from the gateway to the monolith, so one
user request is one trace across both processes. This replaces the request id that
used to be lost between them. `X-Request-ID` is still forwarded and logged on both
sides. Look up a slow request in the logs by its `trace_id`.

## Configuration

| Variable | Values | Notes |
|---|---|---|
| `OTEL_EXPORTER` | `none` (default), `stdout`, `otlp` | Anything else refuses to start: a typo must not silently mean "no telemetry" |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | e.g. `http://otel-collector:4318` | OTLP over HTTP. All the standard `OTEL_EXPORTER_OTLP_*` variables apply (`_HEADERS`, `_TIMEOUT`, per-signal endpoints) |
| `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES` | standard | Added to the resource; they win over the defaults |
| `DEPLOYMENT_ENVIRONMENT` | e.g. `staging` | Defaults to `production` on Cloud Run, `local` elsewhere |

Resource attributes on every signal: `service.name` (`gateway` or `monolith`),
`service.version` (the Cloud Run revision), `deployment.environment.name`, and the
older `deployment.environment`. Traces are sampled `ParentBased(AlwaysSample)`. When
traffic grows, set `OTEL_TRACES_SAMPLER=parentbased_traceidratio` with
`OTEL_TRACES_SAMPLER_ARG=0.1`.

Both processes flush buffered telemetry on SIGTERM, within the shutdown window.

## Metrics

| Route (gateway) | What |
|---|---|
| `GET /metrics` | The gateway's registry |
| `GET /metrics/monolith` | The monolith's registry, fetched over the internal gRPC connection (`OpsService.ScrapeMetrics`) |

Both need `Authorization: Bearer $METRICS_TOKEN`. On Cloud Run without
`METRICS_TOKEN`, neither route is served at all. Locally they are open.

**Why a gRPC call rather than a localhost listener:** on Cloud Run the gateway and the
monolith are separate services, so there is no shared localhost. The internal gRPC
connection is already authenticated with the shared secret. They are two routes, not
one merged exposition, because both processes export the Go runtime collectors under
the same names.

Business metrics added in 29D (low-cardinality labels only, never a user or a product
id):

| Metric | Labels |
|---|---|
| `credits_spent_total` | none |
| `purchases_verified_total` | `platform` (`ios`, `android`), `kind` (`consumable`, `subscription`) |
| `analytics_events_ingested_total` | `family` (`session`, `screen`, `action`, `flow`, `friction`, `server`) |
| `analytics_events_dropped_total` | `reason`: a fixed set (`unknown_event`, `unknown_attribute`, `wrong_type`, `string_too_long`, `not_identifier`, `not_allowed`, `out_of_range`, `too_many_attributes`, `clock_skew`, `bad_envelope`, `bad_version`, `unknown_screen`, `unknown_flow`, `server_only`, `buffer_full`, `flush_failed`, `opted_out`, `duplicate`, `disabled`) |
| `analytics_buffer_depth` | none |
| `analytics_flushed_batches_total`, `analytics_flush_failures_total` | none |

| `analytics_reports_total` | `part` (`build`, `email`, `upload`), `outcome` (`done`, `failed`) |

Alert on: `analytics_flush_failures_total` rising (the database refuses writes);
`analytics_events_dropped_total{reason="buffer_full"}` rising (ingest is faster than
flushing); and `notification_outbox_dead_lettered_total` rising (existing).

## Running an OpenTelemetry Collector

Run one Collector, point both services at it with `OTEL_EXPORTER=otlp` and
`OTEL_EXPORTER_OTLP_ENDPOINT`, and let the Collector fan out. Use the
`otel/opentelemetry-collector-contrib` image, pinned to a release.

### To Elasticsearch and Kibana

```yaml
# otel-collector.yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
processors:
  batch: {}
exporters:
  elasticsearch:
    endpoint: https://elasticsearch.example:9200
    auth:
      authenticator: basicauth
    # Logs (including the analytics event records) and traces land in
    # separate data streams; build Kibana dashboards on event.name.
extensions:
  basicauth:
    client_auth:
      username: ${env:ES_USER}
      password: ${env:ES_PASSWORD}
service:
  extensions: [basicauth]
  pipelines:
    traces: {receivers: [otlp], processors: [batch], exporters: [elasticsearch]}
    logs:   {receivers: [otlp], processors: [batch], exporters: [elasticsearch]}
```

The raw event archive (`gs://$ANALYTICS_ARCHIVE_BUCKET/analytics/raw/YYYY/MM/DD.ndjson.gz`)
is one JSON document per line, so it can be bulk-loaded into the same cluster for
history older than the Collector.

### To Prometheus and Grafana

Either let Prometheus scrape the two gateway routes directly:

```yaml
# prometheus.yml
scrape_configs:
  - job_name: gateway
    scheme: https
    metrics_path: /metrics
    authorization: {credentials_file: /etc/prometheus/metrics_token}
    static_configs: [{targets: ["api.example"]}]
  - job_name: monolith
    scheme: https
    metrics_path: /metrics/monolith
    authorization: {credentials_file: /etc/prometheus/metrics_token}
    static_configs: [{targets: ["api.example"]}]
```

or receive OTel metrics in the Collector and expose them for Prometheus (`exporters:
prometheus: {endpoint: 0.0.0.0:8889}`), with traces going to Grafana Tempo
(`exporters: otlp/tempo`). In Grafana, add Prometheus and Tempo as data sources, and
link logs to traces on `trace_id`.

### Locally

`OTEL_EXPORTER=stdout` prints spans, metrics (every minute) and event log records to
stderr, which is enough to see a trace cross both processes in `docker compose logs`.

## Analytics storage at a glance

Raw events live in `analytics.events`, partitioned by server UTC day, for
`ANALYTICS_RAW_RETENTION_DAYS` (default 14). The scheduled tick:
- creates partitions three days ahead;
- aggregates each complete day into the `analytics.daily_*` tables (once per day,
  idempotent);
- archives each day past the retention to Cloud Storage, then drops it.

Days are Asia/Colombo calendar days for the aggregates and the report (raw
partitions stay UTC days). After 06:00 Colombo the tick builds yesterday's Excel
report from the aggregates, emails it to `ANALYTICS_REPORT_RECIPIENTS` and stores it
at `analytics/reports/YYYY-MM-DD.xlsx`; `cmd/analyticsreport --date` regenerates any
day (runbook §14).

Without `ANALYTICS_ARCHIVE_BUCKET` the archive is skipped with a warning, and the day
is still dropped once it is aggregated. The Cloud Run service account needs
`roles/storage.objectCreator` on that bucket. The upload is create-only, so a retry
never overwrites an archive. See `docs/api/analytics.md` for the event contract.
