# Full review, 2026-10-21: security, algorithms, patterns, architecture, scalability

Scope: current working tree (uncommitted changes included), four read-only reviews (auth and gateway; meetup module and database; architecture and operations; Flutter client). Nothing was run or load-tested; every finding comes from reading code. Test users, seeded test emails and the scoped OTP bypass are intentional and were not counted (see `TESTING-NOTES.md`). Not covered: `grpcapi/*`, `monolithclient/*`, `notification/fcm.go`, `notifications.go`, `lifecycle.go`, `completedrecompute.go`, `geocoding`, `cmd/backfill-*`, billing/IAP (the `billing` and `sos` module directories are empty; SOS lives in `auth/sos`).

Earlier findings are in `docs/security-review-2026-10-01.md` (V-1..V-17) and `docs/gap-tracker.md` #51-#76. This file adds only what is new or changes status. Tracker rows: #77-#96.

## 0. Remediation status (updated 2026-10-22 — Plan 28A COMPLETE)

Phase A of Plan 28 is finished; every item below is closed in the working
tree with a test that failed before the change and passes after. Nothing
is deployed and no migration has been applied to production.

| Finding | Tracker | Closed by |
|---|---|---|
| N-C1 background loops need CPU | #77 | `minScale: "1"` + `cpu-throttling: "false"` in both manifests, guarded by a test |
| N-D1/D2/D3 SOS can hang or never send | #78 | 15 s deadline on every auth request (SOS 10 s + one retry); location optional end to end; `_confirm()` always lands on Retry / Call emergency services |
| N-B1 request uniqueness | #79 | Migration 0019 partial unique index + D1 conditional insert + 23505 → `ErrConflict` |
| N-A1 OTP budgets keyed on casing | #82 | Migration 0020 normalised target column; normalisation at every entry point and in the limiter keys |
| N-A2 refresh rotation not atomic | #83 | Conditional `UPDATE … RETURNING` in the child insert's transaction; reuse revokes the family |
| N-B2 withdraw after the meetup ended | #84 | Withdraw guarded on meetup status and window; completed-count recompute enqueued |
| N-B3 full meetup never reopens | #85 | `ReopenMeetupIfSeatFreed` under the meetup lock |
| N-B4 rating aggregate race | #86 | `pg_advisory_xact_lock` in both rating paths, sorted lock order in the review path |
| N-A6/N-A9 bypass and sender guard-rails | #92 | Global bypass refused on Cloud Run; prod refuses without real senders; Twilio bodies redacted; phone list normalised and validated |
| N-A7 no `aud` | #93 (part) | Audience stamped and verified |
| V-5 debug-signed release | #55 | `key.properties` signing config; release build fails without it |
| N-D4/D6/D7/D10 client hardening | #94 (part) | `allowBackup=false` + extraction rules; `INTERNET` in the main manifest; obfuscation on prod targets; `debugPrint` gated on `kDebugMode` |

Still open and carried into **Phase B**: N-H1/N-H2 (#81), N-A3 (#80),
N-A4 (#91), N-B5..B12 (#87, #88, #89, #90), N-H3 (`/metrics`, #93),
N-D5/N-D9 (#94). **Phase C**: N-M1..M5, N-L1..L4, N-D11..D13 (#95, #96).

Full detail with failing-before output: `docs/plans/28A-completion-report.md`.

## 1. Status of earlier findings

| Finding | Status now |
|---|---|
| V-1 OTP attempt race | Fixed in working tree (atomic claim, conditional consume). **Weakened by N-A1** (casing gives separate budgets) |
| V-2 double accept, V-10 cancel guard | Confirmed closed (meetup locks in consistent order, host and status in the `UPDATE`) |
| V-3/V-4 rate limit keying and memory | Open (see N-H1, N-H2) |
| V-5 Android release signed with debug key | **Open**, still in `build.gradle.kts` |
| V-6 canonicalisation | Email done; phone half and OTP target keys still open (N-A1) |
| Refresh rotation fork (#57) | **Open**, confirmed: `MarkRefreshTokenReplaced` has no `replaced_by IS NULL AND revoked_at IS NULL` guard |
| Request uniqueness (#58) | **Open**, confirmed in migration 0002 line 110; with a griefing path (N-B1) |
| V-17a refresh error clears session | Partly addressed; any non-auth error path to verify |
| V-17b auth HTTP timeouts | Meetup client has 20 s; **auth client has none** (N-D1) |

## 2. Highest priority (do first)

1. **N-C1 Background loops need CPU Cloud Run does not guarantee (High).** `service.yaml.template` has `minScale: "0"` and no `cpu-throttling: "false"`. The notification outbox, lifecycle poller (reminders, auto-close), user-deleted purge and retention sweeps stall when idle; account-deletion purge latency is unbounded. Fix: `run.googleapis.com/cpu-throttling: "false"` plus `minScale: 1`, or move sweeps to Cloud Scheduler.
2. **N-D1/N-D2/N-D3 SOS can hang or never send (High).** Auth-service calls (`refreshSession`, `triggerSos`, `updateLastKnownLocation`) have no timeout; SOS waits up to ~16 s for a GPS fix and is **blocked entirely** if location is unavailable (lat/lng are required); offline failures escape `_confirm()` and leave the dialog in "sending". Fix: 15 s deadline wrapper, fall back to last known location or send without coordinates, catch every error with Retry and Call emergency services.
3. **N-B1 Request uniqueness breaks re-request flows (High).** `UNIQUE(meetup_id, requester_id, status)`. A requester rejected once and re-requesting makes the host's reject return 500, makes the final-seat accept roll back (auto-reject collides), and blocks withdrawing a second acceptance. Griefing: the host can neither fill the last seat nor reject. Fix: partial unique index on `(meetup_id, requester_id) WHERE status IN ('pending','accepted')`, reject re-requests per policy, map 23505 to conflict.
4. **N-A3 SOS/share is an SMS and email abuse channel (High).** Trusted contacts do not consent; the alert body contains up to 500 characters of user text; share route has only the 20/min IP limiter; the 3-contact cap is count-then-insert. Fix: contact opt-in (OTP or link), templated text, per-user and per-contact daily caps, atomic cap. (Extends #61.)
5. **N-H1/N-H2 Rate limits behind Cloud Run (High).** `clientIP` uses `RemoteAddr` only, no `X-Forwarded-For`: either all callers share a few buckets (self-inflicted 429s, the 5/day guest signup spent by the first five callers) or limits are ineffective. Limits are per instance with `maxScale: 8`. Fix: trusted-hop XFF parsing, shared counters (Postgres table or Cloud Armor) for OTP/login/phone.
6. **V-5 release signing** still open. Create the keystore, wire `key.properties`.

## 3. Security findings (new)

| ID | Sev | Finding | Fix |
|---|---|---|---|
| N-A1 | Med | OTP budget, cooldown and per-email limiter key on the raw typed email; login looks up case-insensitively. `Victim@x.com` and `victim@x.com` get separate codes, 5 attempts each, and all mail the victim. Phones also not normalised | Normalise (trim, lowercase, strip phone spacing) at the top of every `Start*`/`Complete*` target path and in the limiter key |
| N-A2 | Med | Refresh rotation not atomic (same as #57, now confirmed in code) | Single conditional `UPDATE ... WHERE replaced_by IS NULL AND revoked_at IS NULL RETURNING` in the same transaction as the child insert; zero rows = reuse, revoke family |
| N-A4 | Med | Work-email check: free-mail list has 7 domains (gmx, proton, yahoo.co.uk, live, msn, aol, me, mail.com pass); unknown company names grant Level 3 before review; `+tag` variants hash differently | Maintained free-mail list, strip `+tag`, decide whether unreviewed claims get Level 3 (ADR-012 policy) |
| N-A6 | Low | `ALLOW_TEST_OTP_BYPASS=true` (all purposes, all accounts) only logs a warning; phone bypass list unvalidated | Refuse to start when set and `K_SERVICE` present; validate phone entries |
| N-A7 | Low | Access tokens 15 min, no `aud`, no revocation; deleted users keep working up to 15 min | Add `aud`; optional deleted-user check on writes |
| N-A8 | Low | Corporate-email start usable as a mail sender (no guest block, case variants bypass limits) | Block guests, normalise, daily cap |
| N-A9 | Low | Logging senders print raw OTP and targets when Twilio/mail keys are unset; a misconfigured prod silently stops sending and logs codes; Twilio error bodies may include numbers | Fail startup in prod without a real sender; redact |
| N-H3 | High | `/metrics` served unauthenticated on the public mux (#71 now with evidence) | Separate internal port or token; Managed Prometheus |
| N-B2 | Med-High | Accepted participant can withdraw after the meetup ended or was cancelled, so co-attendees can no longer rate them and the host alone can; `meetups_completed` not recomputed | Guard the withdraw query on meetup status and window |
| N-B10 | Med-Low | Private safety-feedback notes surface on public host profiles (`ListMeetupReviewComments` lacks `review_completed_at IS NOT NULL`) | Add the filter; store safety notes separately |
| N-B11 | Low-Med | `GetMeetup`/`RequestToJoin` do not enforce the radius; exact coordinates returned for any known id | Enforce `ST_DWithin` with host/participant exceptions if the radius is a product rule |
| N-D4 | Med | Android `allowBackup` not disabled | `allowBackup=false` plus `dataExtractionRules` |
| N-D5 | Med | No `FLAG_SECURE` / app-switcher blur on OTP, trusted contacts, SOS | Native flag via channel; iOS blur overlay |
| N-D6 | Med | No `--obfuscate --split-debug-info` in release builds | Add to prod build targets |
| N-D7 | Low | `INTERNET` declared only in debug/profile manifests; release works via plugin merge by accident | Declare in main manifest |
| N-D8 | Low | LinkedIn redirect uses a custom scheme another app can claim (state is checked, PKCE unsupported by LinkedIn) | Prefer App/Universal Links if LinkedIn allows; document |
| N-D9 | Low | Typed place queries and focus coordinates go to Photon, Nominatim, Stadia | List processors in the privacy policy; consider proxying |
| N-D10 | Low | `debugPrint` of auth errors not gated | `kDebugMode` |

## 4. Algorithms, data structures and query cost

| ID | Sev | Finding | Fix |
|---|---|---|---|
| N-B5 | Med | Browse query does `DISTINCT ON (m.id)` with a ratings LATERAL and a correlated accepted-count for every meetup in 50 km, then re-sorts and limits, so each page redoes the whole radius set (extends #70) | `LEFT JOIN LATERAL ... LIMIT 1`, apply keyset and `LIMIT` before the joins, partial index `(created_at DESC, id DESC) WHERE status='open'`, store `accepted_count` on the meetup row, store rating aggregates on the display cache |
| N-B6 | Med | `RecomputeMeetupsCompletedForParticipants` counts all completed meetups per participant with an `OR` that prevents index use | `UNION` of an indexed host count and an indexed accepted-request count, partial indexes on `status='completed'`, or increment by delta |
| N-B7 | Med | Lifecycle sweeps do not use `idx_meetups_lifecycle_sweep`: auto-close filters on `window_end` (second column); starting-soon uses a non-sargable `window_start - now()` | Index `(window_end) WHERE status IN ('open','full')`; rewrite as `window_start <= now() + interval '30 minutes'` |
| N-B3 | Med | A full meetup is never reopened after a withdrawal; the seat is lost and the meetup leaves browse | Reopen in the withdraw transaction when accepted count drops below capacity |
| N-B4 | Med | Concurrent raters of one user each compute the aggregate from their own uncommitted row; the cache publishes N+1 when the truth is N+2 | `pg_advisory_xact_lock(hashtext(rated_id))` or a post-commit recompute event |
| N-B9 | Med | Nearby notify: `LIMIT 500` with no `ORDER BY`, hardcoded 50 km, no per-host creation cap | Order by distance, cap and rate-limit creation, batch token lookup |
| N-B12 | Low | `ListActiveMeetups` filters 200+200 rows in Go; pending requests are not notified on cancel; solo self-complete can inflate `meetups_completed`; device-token upsert reassigns a token to whoever submits it; ratings can be self-confirmed once the window starts; no collusion control | Individually small; see tracker |

Scalability ceiling (reading only): 10k users, correctness bugs (N-B1..B3) bite before load. 100k, browse (N-B5), recompute (N-B6), synchronous bus in `CreateMeetup` (N-B8) and 60 s sweeps (N-B7) exhaust the 20-connection pool with a 10 s `statement_timeout`, starving auth and meetup together. 1M, the single in-process outbox poller with sequential delivery and retention growth in requests, ratings and outbox tables.

## 5. Architecture and design patterns

Scores (1-5): modularity 4, security posture 3, scalability 2, observability 3, testability 4, operability 3.

Strengths: module boundaries hold (no cross-schema FKs, wiring only in `cmd/monolith/main.go`); outbox uses `FOR UPDATE SKIP LOCKED` with backoff and dead-lettering; fail-fast config and secrets; distroless nonroot static image; pool arithmetic (20 x 8 = 160 of 200) documented; per-RPC deadlines, `statement_timeout`, graceful shutdown; repository, strategy (senders), breaker and outbox patterns used sensibly; interfaces at test seams.

| ID | Sev | Finding | Fix |
|---|---|---|---|
| N-M1 | Med | In-process bus has a documented loss window feeding denormalised caches (display, location, subscription, rating, `meetups_completed`); no scheduled reconcile | Route cache-feeding events through the outbox or run a periodic reconcile; alert on lag |
| N-B8 | Med | Bus is synchronous: `CreateMeetup` latency includes the nearby-notify fan-out; events lost on crash between commit and publish | Bounded async worker or transactional outbox, handlers under their own timeout |
| N-M2 | Med | Gateway and monolith are sidecars in one Cloud Run service: they scale, fail and bill together; every instance runs all pollers | Accept as one deployable and say so, or split into two services |
| N-M3 | Med | CI has no `govulncheck`, gosec, secret scanning, SBOM or image scan; no Dependabot; actions pinned to tags; no top-level `permissions:`; base images by tag; deploys manual | Add each; SHA-pin; digest-pin bases; deploy job with Workload Identity Federation |
| N-M4 | Med | Backup workflow uses a long-lived JSON key; no restore drill; 30-day retention | Workload Identity Federation, periodic restore test, failure alert |
| N-M5 | Med | Migrations manual and hand-ordered; nothing checks schema version against the image | Startup schema-version check or a migration job |
| N-L1 | Low | Docs list modules `billing` and `sos` that are empty (SOS is in `auth/sos`); Gmail SMTP is the preferred prod sender (low limits, no failover) | Update ADR-001 and docs; transactional email provider |
| N-L2 | Low | God files: `main.go` 691, `meetups_postgres.go` 1264, `meetup/service.go` 944, `handlers/meetups.go` 832, `monolithclient/meetup.go` 716 | Per-module `RegisterSubscriptions`, a `wiring` package |
| N-L3 | Low | No tracing (OpenTelemetry indirect only); completed-meetups poller unobserved | Cloud Trace; alerts on outbox pending and dead-letter counts |
| N-L4 | Low | Breaker only around SOS and push; none on the gateway-to-monolith client | Acceptable on localhost; deadlines are the mitigation |
| N-D11 | Med | Flutter: 157 `ref.watch(` calls, zero `.select(`; big pages rebuild on any change; `authSessionProvider` holds profile, session and trust level together and is watched in 12 places | `select` for trust level, user id, name; split big pages |
| N-D12 | Med | `AuthService` is a god interface; `HttpAuthService` is 1118 lines (sign-in, OTP, SOS, contacts, location, deletion, deep links) | Split into SignIn, Verification, Safety, Account services; share one HTTP helper with the meetup client |
| N-D13 | Low | 64 imperative `Navigator.push` calls, no router; deep linking is disabled and routed by hand | Adopt a router before adding deep links |

Largest Dart files: `profile_page.dart` 1517, `events_page.dart` 1484, `meetup_detail_page.dart` 1419, `schedule_flow.dart` 1303, `http_auth_service.dart` 1118. Test gaps: no tests for chats, privacy, splash; SOS failure paths untested.

Top five by value over effort: (1) `cpu-throttling: "false"` plus `minScale: 1`; (2) XFF client IP and shared OTP/login limits; (3) protect `/metrics` and alert on outbox depth; (4) CI scanning and Dependabot; (5) cache reconcile or outbox-backed cache events plus a schema-version check.

## 6. Checked and clean

Own JWT validation (RS256 pinned, `iss`, `kid` rotation); federated tokens (audience, expiry, issuer allowlist, constant-time nonce, hardcoded JWKS URLs, linking by `(provider, subject)`); LinkedIn (5 s timeout, no SSRF); internal gRPC secret (constant time, duplicates rejected); user ids from verified context on every handler read; OTP generation (`crypto/rand`, hashed, constant-time compare, 10 min expiry); account claim order; request body cap and server timeouts; all SQL parameterised; accept path locking; advisory lock on schedule conflict; review submission uniqueness; participant redaction; secure token storage and logout wipe on the client; no cleartext in release; no WebView or clipboard use; timers and subscriptions disposed; secrets gitignored (`git ls-files` shows only `.gitkeep` and README in `backend/secrets`); tracked Firebase client configs are client keys, not secrets.

## 7. Suggested order of work

1. Plan 28 (small, high value): N-C1, N-H1, N-H3, V-5, N-D1/N-D2/N-D3, N-A1, N-B1 (with migration), N-B2, N-B3.
2. Plan 29: refresh rotation atomicity (N-A2), contact consent and SOS caps (N-A3), N-B5/N-B6/N-B7 query and index work, N-B10.
3. Plan 30: CI supply chain, Workload Identity Federation, schema-version check, cache reconcile, splitting `HttpAuthService`.
