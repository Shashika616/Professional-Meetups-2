# Full review, 2026-11-01: whole codebase after Plan 29

Scope: the current working tree (last commit `f5a5ec3`; Plan 28 and Plan 29 changes uncommitted), backend, Flutter app, CI and deploy files, docs. Four independent read-only reviews: auth, gateway and billing; meetup, database and location; architecture, operations and analytics; Flutter client. Nothing was run, built or changed. This complements the implementer's review `docs/security-review-2026-11-01.md` (Plan 29 code only); its S-1, S-2, S-3 fixes were re-checked and hold.

Test users, seeded test emails and the scoped OTP bypass are intentional (`TESTING-NOTES.md`). The bypass guard was re-checked and holds: the global flag refuses to start on Cloud Run, the email allowlist needs reserved TLDs, the phone allowlist is exact-match and purpose-scoped. Note: listed test phone numbers are real numbers, so whoever registers them first owns them.

Tracker rows: #100-#121 in `docs/gap-tracker.md`.

## 1. Fix before the next deploy

| ID | Sev | Finding | Fix |
|---|---|---|---|
| N1-H1 | High | `backend/service.yaml` is gitignored (`.gitignore:13`) but `deploy_manifest_test.go` fails without it and `deploy.yml` applies it, so CI's test job fails on a clean checkout and the deploy workflow cannot run from one | Commit a placeholder-free manifest or generate it in the workflow; test the template when the file is absent; gate `deploy.yml` on green CI and a protected environment |
| N1-B2 | High | Migration 0019's partial unique index can fail on production data: the old key allowed one pending and one accepted row for the same person and meetup | Add a duplicate check to the runbook and a cleanup step in 0019 (keep accepted, mark extra pending as withdrawn) |
| N1-M1 | Medium | All of Plan 29 (billing, analytics, telemetry, migrations 0025-0032, CLIs) is untracked: never run by CI, no copy off this disk | Commit on a branch and push |
| N1-H2 | High | Cron tick runs up to 150 s but the gateway `WriteTimeout` is 30 s: Cloud Scheduler records failures and retries whole ticks, analytics sweeps (last in the list) get cut, and the 30 s per-sweep cap undercuts the 120 s aggregation timeout | Per-route write deadline for the tick, larger budgets for analytics sweeps or a second Scheduler job |
| N1-M2 | Medium | Manifests lack analytics, OpenTelemetry and store settings (`ANALYTICS_USER_KEY_SECRET`, `ANALYTICS_ARCHIVE_BUCKET`, `GOOGLE_PUBSUB_PUSH_SERVICE_ACCOUNT`, store credentials); the template still has the Cloud SQL annotation, no `CRON_SHARED_SECRET`, revision r22 | Add them and extend the manifest test |

## 2. Security and privacy

| ID | Sev | Finding | Fix |
|---|---|---|---|
| N1-B1 | High | `GET /v1/users/{id}` lists a member's next five open or full meetups with times and place labels (`member.sql ListRecentMeetupsForMember`, `WHERE m.status <> 'cancelled'`), to any signed-in user including guests, for anyone who has ever hosted, including meetups they only joined. It bypasses Level 0 redaction and the participant identity floor | Only completed or ended meetups unless the viewer was on it; pass the viewer's trust level and apply `redactForViewer` |
| N1-A1 | Medium-High | Email login/signup start and account-claim resend have no per-target cap: a new code every minute with 5 guesses each (attempts reset per code), about 7,200 guesses a day against one passwordless account; each start sends a real email through Gmail SMTP, so the daily quota can be exhausted | Add the routes to `targetKeyedPaths`; daily send and failed-guess budgets per normalised target in Postgres that do not reset on resend; a transactional email provider |
| N1-A2 | Medium | Per-target and per-email limiters read `parsed["email"]` exactly, while `encoding/json` matches keys case-insensitively: `{"EMAIL": ...}` or duplicate keys skip the limit (SMS bombing on `phone/start`) | Case-insensitive peek that refuses duplicate keys, or enforce the limit in the service after decoding |
| Location 1 (#90) | Medium-High | `GetMeetup` returns exact coordinates to any caller at any distance; for "use current location" meetups that is the host's GPS position | Enforce the radius with host and participant exceptions; null coordinates for Level 0 |
| N1-D1 | Medium | The app's privacy page says "approximate location, only while browsing", but the last-known upload is full precision and the meetup page's "other meetups nearby" can start a location read and upload when Home is not mounted | Round to 3 decimals before upload; read-only cached value in `OtherMeetupsNearby`; align copy |
| N1-M3 | Medium | Raw analytics archives in Cloud Storage keep `user_key` and `install_id`, have no lifecycle rule, and are not erased on account deletion or opt-out | Lifecycle rule (for example 90 days) stated in the privacy policy, or strip identifiers before archiving |
| N1-A3 | Medium (policy) | An unknown company at work-email verification still grants Level 3 before review (remaining half of #91); no disposable-mail domains in the list | Level 3 only for known company domains, or hold pending review |
| N1-A4 | Medium-Low | Trusted contacts' emails are never confirmed (only phones), so alerts can be pointed at any inbox; meetup share has no per-user or daily cap; outgoing texts carry the user-controlled name (200 characters) | Confirm or drop contact email; cap shares; shorten and strip URLs from names in texts |
| N1-B5 | Low-Medium | Sharing a cancelled or ended meetup is allowed; no cap on contact ids; `safety_share` rows recorded for contacts not notified | Require a live meetup, cap and dedupe ids, record only notified contacts |
| Location 2-8 | Medium/Low | Join radius fails open and uses cache rows of any age; stale `user_location_cache` never swept; SOS and meetup coordinates kept indefinitely; Nominatim error log can contain the request URL with coordinates, no cache or throttle, unbounded body, placeholder User-Agent; browse coordinates in URL query; 50 km hard-coded in four places with stale 40 km comments | Tracker #108 and #118 |
| N1-D2 | Medium (billing) | A credit pack redelivered by the store before the catalog loads, or while the Premium page is open, goes to the subscription verifier and fails ("Could not verify your purchase"); retried only while those pages are open | One app-level purchase listener routing by product id |
| N1-B3 | Medium | Join and accept do not check that the meetup window is still running (until auto-close, which waits for a tick) | Add `window_end > now()` to the conditional insert and the locked accept check |
| N1-B4 | Medium | Notification outbox visibility timeout (60 s) can be shorter than a slow batch, so another instance re-claims and pushes twice | Timeout at least batch size times per-row deadline, or re-stamp per row; owner check on mark-processed |
| N1-A7 / V-4 / #81 | Medium | Rate limiter is in memory per instance with no size cap; keys use the raw path so every 404 and every meetup id gets a fresh bucket | Key on route pattern, cap the map, shared counters for OTP routes |
| N1-L2 | Low | Raw `install_id` (up to 64 KB) used as a limiter key before validation | Validate UUID at the gateway |
| N1-L3 | Low | Gateway trusts inbound `traceparent` and baggage (clients choose sampling, inject baggage) | New root span at the edge, drop baggage |
| N1-L4 | Low | Analytics `id`-typed attributes accept UUIDs | Refuse UUID shapes or use enums |
| N1-A5 | Low | Google JWKS refetched under a lock for every unknown kid | Rate-limit refetch, negative cache |
| N1-A6 | Low | Same as N1-H2 from the gateway side | — |
| N1-B6 | Low | Reused `Idempotency-Key` with different parameters returns the old meetup with 200 instead of 409 | Store a request hash with `creation_key` |
| N1-B7 | Low | Reviews and ratings accepted months later (14-day window enforced only for the Home list) | Enforce the window in both submit paths |
| N1-D3..D8 | Low | `minSupportedAppVersion` parsed but not enforced; credit client has no 426 branch; analytics install id survives sign-out; 429 on refresh at launch shows sign-in without signing out; SOS Retry sends a new alert without saying so; opt-out mid-flush still sends that batch | Individually small; see the client section of the tracker |
| N1-M4 | Medium (ops) | Report regeneration overwrites `analytics/reports/<day>.xlsx` but the runbook grants only `objectCreator` | Grant `objectUser` or treat 412 as done |
| N1-M5 | Medium | Server analytics events from outbox drains go to the in-memory buffer and the outbox row is marked done: lost on a kill; the tick never flushes | Final `analytics: flush` sweep |
| N1-L1 | Low | Archive gzips a whole day in memory | Stream the upload |

Unchanged accepted items: N-D8 custom URL scheme for LinkedIn OAuth (state checked), N-L4 no breaker on the gateway to monolith client, N-M2 sidecar deployment, N-A7 access tokens usable up to 15 minutes after deletion.

## 3. Status of earlier findings

Fixed and re-verified: V-1, V-2, V-5, V-10, V-17a (leftover N1-D6), #79, #82, #83, #84, #85, #86, #92, `/metrics` (#93), JWT `aud`, client IP from the trusted hop (V-3), N-B6, N-B10, N-D1, N-D2, N-D3, N-D4, N-D5, N-D7, N-D9, N-D10, N-H1, N-H3, N-M5, S-1, S-2, S-3. Duplicate SOS on the automatic retry is handled server-side.

Partial: #80 (phone consent and templated text done; email consent and share caps open), #87 (browse page chosen first, but radius filter still sorts every open meetup in range; lifecycle sweep indexes not added), #88 (completed count has an outbox; display, location and rating caches still use the bus; no reconcile), #89 (nearest-first and per-host cap done; synchronous, 500 single-row inserts), #91, #95 (scanners, Dependabot, pinned actions, WIF deploy and backups done; base images not digest-pinned, no SBOM or image scan, deploy not gated), N-C1 (cron tick, but N1-H2), N-D6 (obfuscation in `build.sh`, not in CI), N-D11, N-D12, N-L3 (OpenTelemetry in place, exporter off, no alert rules), N-M4 (restore drill manual).

Open: #81/V-4/S-9 (in-memory limiter), #90 geo-visibility, location items 1-8, N-B7, N-D13 router, #96 file sizes (growing: `meetups_postgres.go` 1343, `meetup/service.go` 1019, four Flutter pages over 1450).

## 4. Scores (1-5)

| Area | Before (10-21) | Now | Why |
|---|---|---|---|
| Modularity | 4 | 4 | Clean boundaries and adapters; large files keep growing |
| Security | 3 | 3 | Many fixes, but OTP brute force, profile leak, coordinates and per-instance limits remain |
| Scalability | 2 | 3 | Partitioned analytics, bounded buffers, sized pool; in-memory limiter and the tick ceiling hold it back |
| Observability | 3 | 4 | OpenTelemetry across gateway, gRPC and pgx, metrics, daily report; exporter off, no alerts |
| Testability | 4 | 4 | Thorough and race-tested; CI cannot pass on a clean checkout |
| Operability | 3 | 3 | WIF deploy, backups and schema check exist; deploy cannot run from git, Plan 29 uncommitted, runbook drift (schema 16, Cloud SQL proxy, "eleven sweeps", "PAUSED") |

## 5. Order of work

1. Commit Plan 28 and 29 on a branch; fix N1-H1 so CI runs; add the 0019 pre-flight.
2. N1-B1, N1-A1, N1-A2, location 1 (#90), N1-D1, N1-H2, N1-M2, N1-M5.
3. N1-M3 before launch (privacy policy), N1-A3 decision, N1-A4, N1-B3, N1-B4, N1-D2, limiter (#81).
4. Remaining location items, lows, runbook refresh, file splits.

## 6. Checked and clean (summary)

Refresh tokens hashed with family revocation; OTP generation, atomic attempts, constant-time compare, uniform login error; federated sign-in checks; internal gRPC secret; Apple JWS chain and Google OIDC with service account; purchase binding, environment checks, one grant per transaction; wallet locking, idempotent holds, refund log, welcome grants; strict decoding and body caps; cron and metrics secrets; contact confirm page headers; no committed secrets; ownership checks on every meetup write; lock ordering; outbox claims with `SKIP LOCKED`; analytics gzip-bomb caps, HMAC user keys, opt-out in the flush transaction, partition maintenance under advisory lock, small-group suppression; distroless non-root images; app tokens in secure storage, purchase completed only after server verification, `autoConsume` false, account binding, no PII in analytics envelope, no WebView, no cleartext, only `MainActivity` exported.
