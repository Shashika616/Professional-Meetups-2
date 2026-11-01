# 29D completion report: analytics module and OpenTelemetry (backend)

This is the working tree only. Nothing is committed, pushed or deployed, and no
production database was touched. Test users, seeded emails and the OTP bypass are
unchanged. 29E has not started.

## Gates

| Gate | Result |
|---|---|
| `gofmt -l .` | Clean |
| `go vet ./...` | Clean |
| `go test -race -count=1 ./...` | All 39 packages with tests pass, against the local Postgres |
| `golangci-lint run ./...` | 0 issues |
| `govulncheck ./...` | No vulnerabilities in called code. One module-level finding, GO-2026-5932 (`golang.org/x/crypto/openpgp`, no fix available), is not reached and predates 29D |
| Migrations | 0030 and 0031 up, down 2, up on a scratch database; schema 31, not dirty |
| Generated code | `sqlc diff` clean; `buf generate` changes nothing; the Dart constants match the registry (test) |
| `flutter analyze` on the generated file | No issues; `dart format` leaves it unchanged |

## New dependencies

All pinned exact, each release at least two weeks old on 2026-10-25:
- `go.opentelemetry.io/otel` with `sdk`, `sdk/metric`, `sdk/log`, `log`, `trace` and the
  `otlp*http` / `stdout*` exporters, all v1.47.0;
- `otlploghttp` and `stdoutlog` v0.23.0;
- contrib `otelhttp` and `otelgrpc` v0.72.0;
- `gopkg.in/yaml.v3` v3.0.1.

Test only, through Prometheus `testutil`: `kylelemons/godebug` v1.1.0 and
`kr/text` v0.2.0. `go mod tidy` is clean.

## Items

| # | Item | Where | Tests |
|---|---|---|---|
| 1 | **OpenTelemetry platform.** Tracer, meter and logger providers. Resource attributes `service.name`, `service.version`, `deployment.environment` (plus `.name`). `OTEL_EXPORTER=none\|stdout\|otlp`, default `none`; an unknown value refuses to start; standard `OTEL_*` variables honoured. Flushed on shutdown. `otelhttp` on the gateway (health checks excluded); `otelgrpc` client and server; W3C `traceparent`. `X-Request-ID` is still forwarded and logged, and logs now carry `trace_id`. A pgx tracer records operation and sqlc name, never arguments. Spans wrap outbox deliveries and store calls | `internal/platform/telemetry`, `platform/db`, `platform/logging`, `platform/outbox`, `billing/store/resilient.go`, both `main.go`s | `telemetry_test.go`; `TestTraceContextPropagatesGatewayToMonolith` (one trace id across an `otelhttp` gateway and an `otelgrpc` monolith over bufconn, in a test exporter) |
| 2 | **Metrics.** The monolith's registry is served at the gateway's token-protected `GET /metrics/monolith`, through a new `OpsService.ScrapeMetrics` RPC (a gRPC call, not a localhost listener: on Cloud Run they are separate services; reasons in `docs/observability.md`). New counters: `credits_spent_total`, `purchases_verified_total{platform,kind}`, `analytics_events_ingested_total{family}`, `analytics_events_dropped_total{reason}`, and buffer depth, flushes and flush failures. Labels are low-cardinality only | `platform/metrics`, `grpcapi/ops.go`, `gateway/handlers/observability.go` | `TestMonolithMetrics_ServedBehindTheSameGuard` |
| 3 | **Registry.** Embedded `events.yaml`: every plan 4.1 event plus `credits_revoked` and `credits_insufficient_shown`, the screen catalogue (28), 9 flows with their steps, 30 catalogued controls, typed attributes. `go generate` writes `frontend/lib/core/analytics/event_names.g.dart` (app events only, so the app has no constant for a server event) | `modules/analytics/registry`, `cmd/analyticsgen` | `registry_test.go`: unknown event, unknown attribute, wrong type, a string over 100 characters, free text, an unlisted enum value, out of range, more than 20 keys, skew, bad ids, unknown screen or flow, server-only events; a broken registry refused; the Dart file up to date |
| 4 | **Schema.** Migration 0030 creates:<br>• `analytics.events`, range-partitioned by server UTC day (`received_day`), PK `(received_day, event_id)`, BRIN on `received_at`, B-tree on `(event_name, received_at)`, a partial index on `user_key`, and a default partition as a safety net;<br>• `ensure_partition` / `drop_partition` functions (advisory-locked; rows that landed in the default partition are moved into the new day's partition);<br>• the tables `partitions`, `opt_outs`, `aggregate_runs`, the six `daily_*` tables, `user_first_seen` and `report_runs`.<br>Own sqlc entry | `migrations/0030_analytics`, `analytics/repository` | Integration tests below |
| 5 | **Ingest.** `POST /v1/analytics/events`, signed in or anonymous by `install_id`:<br>• gzip, decoded under the 64 KB cap (no zip bombs);<br>• at most 50 events;<br>• 30 batches a minute per user or install;<br>• the per-IP ceiling raised to 300 a minute for this path only, since many phones share one NAT;<br>• strict JSON;<br>• envelope and registry validation, 7-day skew window;<br>• `202 {accepted, dropped}` as soon as events are queued.<br>The bounded buffer (10,000) never blocks: when full it drops and counts. It flushes every 2 s or at 500 events, and on shutdown, by `COPY` into a temporary stage; opted-out keys are removed; `INSERT ... ON CONFLICT DO NOTHING`. Each written event is also an OTel log record, emitted by the flusher. Respects `analytics.enabled` (an unreadable flag counts as off) and opt-outs | `gateway/handlers/analytics.go`, `monolithclient/analytics.go`, proto `analytics/v1`, `grpcapi/analytics.go`, `modules/analytics/{analytics,buffer}.go` | Gateway: 51 events → 413, 65 KB → 413, a gzip bomb → 413, the 31st batch → 429 per user and per install, unknown fields → 400. `TestRateLimit_AnalyticsHasAHigherIPCeiling`. Module: `TestADuplicateEventIDIsStoredOnce`, `TestIngestLimits`, `TestTheKillSwitchDropsEverything`, `TestAFullBufferDropsWithoutBlocking` |
| 6 | **Server domain events**, from outboxes, never the bus. Every adapter cannot fail and derives a stable event id from the outbox row, so a redelivery is stored once.<br>• **Billing outbox:** `credits.changed` becomes credits granted, spent, refunded, expired or revoked; also `purchase.verified` and `subscription.*`.<br>• **Meetup billing outbox:** `meetup_created`.<br>• **Meetups-completed outbox:** `meetup_completed`.<br>• **New meetup activity outbox:** `join_requested`, `request_accepted` (see decision 3) | `cmd/monolith/analytics_wiring.go`, `migrations/0031_meetup_activity_outbox`, `meetup/repository/activity_outbox_postgres.go`, `billing/outbox.go` (`OutboxEvent.ID`) | `analytics_wiring_test.go` (mapping; garbage never fails a billing row; the tap runs first and keeps the delivery's error); `TestJoinAndAcceptAlwaysLeaveAnActivityRecord` |
| 7 | **Sweeps** on the scheduled tick:<br>• partitions three days ahead (also at start-up);<br>• nightly aggregation of each complete day, idempotent by date;<br>• archive and retention: export as gzip NDJSON to `gs://$ANALYTICS_ARCHIVE_BUCKET/analytics/raw/YYYY/MM/DD.ndjson.gz` (metadata-server token, JSON API, create-only upload, hard-coded endpoints), then drop partitions older than `ANALYTICS_RAW_RETENTION_DAYS` (14).<br>A day is always aggregated before it is dropped; a failed upload keeps the partition. Without a bucket the archive is skipped with a warning. The activity outbox is drained by the tick, with retention | `modules/analytics/{sweeps,archive}.go`, `cmd/monolith/main.go` | `TestPartitionsAreCreatedAheadIdempotently`, `TestADayWithoutAPartitionIsRescuedFromTheDefault`, `TestAggregationIsIdempotent` (exact rows, re-run identical), `TestRetentionArchivesThenDrops` (failure keeps the data; archive content checked; second run is a no-op), `TestRetentionWithoutABucketSkipsTheArchiveCleanly`, `TestScheduledTickRunsEveryAnalyticsSweep` |
| 8 | **Deletion and opt-out.**<br>• User deletion (a consumer of the user-deleted outbox) flushes the buffer, then deletes the account's events, cohort row and opt-out.<br>• `PUT /v1/analytics/consent` (signed in) stores the opt-out, and opting out also deletes what was stored. Events still sent afterwards, including the server's own, are dropped at flush | `analytics.go`, `repository.go`, `gateway/handlers/analytics.go` | `TestOptOutDeletesAndDrops`, `TestUserDeletionRemovesTheirData` (including an event still queued when the deletion arrives), `TestNoRawIdentifierIsStoredAnywhere` (scans every row of every analytics table and partition for the raw user id, the email and the name an event tried to carry), `TestAnalyticsConsent` |
| 9 | **Docs** | `docs/api/analytics.md` (envelope, every event, limits), `docs/observability.md` (Collector to Elasticsearch and Kibana, Prometheus and Grafana; nothing deployed), `docs/privacy-analytics-notes.md` (facts for the policy update) | |

For the key tests, I broke the code they guard and confirmed each one fails:
- a blocking `Offer`;
- no opt-out filter;
- no buffer flush before deletion;
- dropping without aggregating;
- dropping after a failed upload;
- the app sending server events;
- ignoring the kill switch;
- storing the raw id instead of the HMAC;
- a larger body cap;
- tapping after the delivery;
- a wrong topic on the accept record.

One mutation was not caught: removing `DISTINCT ON` from the flush. That mutant is equivalent, because `ON CONFLICT DO NOTHING` already skips a key repeated in the same statement. I removed the redundant code.

## Load test

`backend/scripts/analytics-load.sh` builds a monolith from the working tree and starts it against the local test database, with a throwaway secret. It then drives `Ingest` over gRPC directly, as the gateway does, and counts what was stored. Run on 2026-10-26 on an Apple-silicon Mac, Postgres in Docker:

| Measure | Result |
|---|---|
| Offered | 200 batches/s × 60 s, 10 events each (2,000 events/s) |
| Batches sent / failed / skipped by the client | 11,979 / 0 / 0 |
| Latency p50 / p95 / p99 / max | 0.61 / **1.02** / 1.73 / 94 ms |
| Events dropped | **0** (registry and buffer) |
| Events stored | 119,790 of 119,790, plus one real `meetup_completed` from the monolith's own auto-close poller |
| Flush failures | 0 |

## Device test (Pixel 8 emulator, 2026-10-26)

The local Docker stack was rebuilt from this tree, and the app (1.1.0+7) was signed in as `l3.a@meetups.test`.

**On the phone:** the app works unchanged against the 29D backend. I scheduled a coffee meetup for 4 people at a cost of 10 credits (balance 53). Within seconds, `meetup_created` and `credits_spent` (capture, 10) were stored with the hashed user key. A scan of the stored rows found no raw user id, email or name.

**Through the real gateway**, with a gzip batch:
- normal app events were stored;
- a forged `credits_granted` was refused;
- an `email` attribute was stripped;
- consent without a session returned 401.

No physical device was connected, so there was no run on real hardware.

## Decisions and findings

1. **Received day, not device time, partitions and reports.** `received_day` is the server's UTC day. Deduplication by `event_id` holds within a day; a retry that crosses UTC midnight could be stored twice. This is accepted as best effort and documented.
2. **No bucket still drops raw days.** Keeping the database inside the free tier is the retention's purpose, and the day is aggregated first. The monolith logs a warning at start-up and each time an archive is skipped.
3. **Join counts needed their own outbox.** At first `join_requested` and `request_accepted` were read from the notification outbox. That outbox has no row when the recipient has no registered device, so those counts would have been low. Migration 0031 adds `meetup.activity_outbox`, written in the same transaction as the request and the accept: ids only, the requester as the user, analytics as the only consumer. It is the one meetup-module change in 29D.
4. **`meetup_created` has no attributes.** The meetup outbox does not carry the cost; the matching `credits_spent` does. `meetup_completed` comes from a row that lists meetups, not people, so it is counted, not tied to an account.
5. **`credits_revoked` was added** for store refunds of packs and negative operator adjustments, so they are not mixed into spends or expiries.
6. **Strict batch JSON.** Unknown fields are a 400, so an app sending an unexpected field (for example an email) fails loudly instead of being half-accepted. A future envelope field needs a server release first.
7. **Opting out deletes.** The prompt asked only for storing the opt-out. Deleting what was already stored makes "off" mean off.
8. **Production without `ANALYTICS_USER_KEY_SECRET` (or one under 32 bytes) collects nothing,** and says so at start-up. A weakly keyed `user_key` is worse than no data.
9. **The OTel log API.** `go.opentelemetry.io/otel/log/global` is deprecated in v1.47.0, so the code uses `otel.GetLoggerProvider` and `otel.SetLoggerProvider`.

## For the owner (nothing here is done)

- **Secret Manager:** create `ANALYTICS_USER_KEY_SECRET` (32+ random bytes) and map it to the monolith service. Until then production analytics are off.
- **Archive:** set `ANALYTICS_ARCHIVE_BUCKET` to the existing bucket and give the monolith's service account `roles/storage.objectCreator` on it. Add a lifecycle rule for `analytics/raw/`, and state its length in the privacy policy.
- **Privacy policy:** update it before 29E ships the client, using `docs/privacy-analytics-notes.md`.
- **Deploy order:** migrations 0030 and 0031 are additive and old app builds are unaffected (they send no events). `service.yaml` is not changed by this plan.
