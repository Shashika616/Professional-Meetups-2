# Plan 28: close every finding from the 2026-10-21 review and lift all six scores to 5/5

Source: `docs/security-review-2026-10-21.md`, tracker #77-#96 (and open earlier items #53-#57, #61, #70, #71). Companion prompt: `28-full-review-remediation-claude-code-prompt.md`.

Scores today (1-5): modularity 4, security 3, scalability 2, observability 3, testability 4, operability 3. Target: 5 on all six.

## Ground rules

- Working tree only. No commit, no deploy, no `gcloud`, no production database. Migrations are written and tested locally, never applied to production.
- Test users, seeded test emails and the scoped OTP bypass stay exactly as they are (`TESTING-NOTES.md`). Nothing here may remove or widen them. The one change near them is N-A6 (refuse `ALLOW_TEST_OTP_BYPASS` on Cloud Run), which must not affect the reserved-TLD email allowlist.
- A provider-verified email still counts as the personal email toward Level 2 (ADR-009).
- Every fix ships with a test that fails before and passes after. Concurrency fixes get a race test (`go test -race`).
- Real content only in the UI. This plan changes no screens except SOS failure states and a consent step for trusted contacts.

## What "5/5" means (exit criteria, all checkable)

| Area | Done when |
|---|---|
| Security | No open High or Medium item from either review except those explicitly accepted in an ADR; rate limits keyed on the real client and shared across instances; OTP, refresh and request flows atomic; CI runs govulncheck, gosec and secret scanning and fails on findings; release builds signed, obfuscated, backups off |
| Scalability | Browse, recount and sweep queries use indexes (EXPLAIN evidence in the report); no in-memory correctness state; background work runs with CPU always allocated or from Cloud Scheduler; cache-feeding events go through the outbox; a load test script shows p95 browse under 300 ms at 100k seeded meetups and no pool exhaustion |
| Observability | Request tracing (OpenTelemetry to Cloud Trace); per-poller metrics (outbox pending, dead letters, lag, sweep duration); `/metrics` private; alert policy file in `docs/deploy/` for outbox depth, dead letters, 5xx rate, pool saturation, backup failure |
| Operability | Deploy workflow (Workload Identity Federation) with a migration job and a startup schema-version check; backup via WIF plus a documented and scripted restore drill; Dependabot; SHA-pinned actions and digest-pinned images; runbook matches reality |
| Modularity | `main.go` under 250 lines (wiring split into `wiring/` and per-module `RegisterSubscriptions`); no Go file over 600 lines; no Dart file over 600 lines; `AuthService` split into four services; docs list only real modules |
| Testability | Tests for chats, privacy, splash, SOS failure paths; Postgres integration tests for each new query; Riverpod `select` used where a page watches a large provider; coverage not lower than today and reported per package |

## Phases (each ends with tests green and a completion report)

### Phase A, correctness and safety (Plan 28A)

| Tracker | Change |
|---|---|
| #77 | `docs/deploy/service.yaml.template`: `run.googleapis.com/cpu-throttling: "false"`, `minScale: "1"`; update runbook cost note |
| #78 | Flutter: one auth `_send` wrapper with 15 s deadline mapping `SocketException`, `ClientException`, `TimeoutException` to `AuthNetworkException`; SOS 10 s deadline and one retry; if location fails, use last known position or send without coordinates (make lat/lng optional in proto, gateway, service); catch every error in `_confirm()` with Retry and Call emergency services; tests for offline, timeout, no location |
| #79 | Migration `0019`: drop `UNIQUE (meetup_id, requester_id, status)`, add partial unique index `(meetup_id, requester_id) WHERE status IN ('pending','accepted')`; `RequestToJoin` rejects when a live row exists and applies the re-request policy (decision D1); map 23505 to `ErrConflict` in accept, reject, withdraw; test the griefing sequence |
| #84 | Withdraw query guarded on meetup status and window; recompute `meetups_completed` on withdrawal |
| #85 | Reopen `full` to `open` in the withdraw transaction under the existing lock |
| #86 | `pg_advisory_xact_lock(hashtext(rated_id))` around aggregate compute |
| #82 | Normalise email (trim, lowercase) and phone (strip spaces and hyphens) at the top of every target-keyed start and complete path and in the limiter key; migration for a normalised target column and unique index on `verification_codes` |
| #83 | Refresh rotation as one conditional `UPDATE ... WHERE replaced_by IS NULL AND revoked_at IS NULL AND expires_at > now() RETURNING` in the same transaction as the child insert; zero rows means reuse, revoke the family |
| #55 | Android release signing from `key.properties`; fail the release build if it is missing; document keystore handling (the keystore itself is created by Shashika, never generated into the repo) |
| #94 (part) | `allowBackup=false` plus `dataExtractionRules`; `INTERNET` in the main manifest; `kDebugMode` gate on `debugPrint`; obfuscation flags in `build.sh` and CI for prod |
| #92 (part) | Refuse `ALLOW_TEST_OTP_BYPASS=true` when `K_SERVICE` is set; refuse startup in production without real SMS and email senders; redact targets and Twilio bodies in logs |
| #93 (part) | Add `aud` to access tokens and verify it |

### Phase B, abuse resistance and scale (Plan 28B)

| Tracker | Change |
|---|---|
| #81 | Client IP from the trusted hop of `X-Forwarded-For` (configurable hop count, tested); shared rate limiter backed by Postgres (`ratelimit.counters`, window and key, atomic upsert) for OTP send, login, phone, SOS, share and corporate-email routes; in-memory limiter stays only as a local pre-filter; bound key length and table growth (hash the key, sweep expired rows); fixes V-4 |
| #80 | Trusted contact opt-in: new contact starts `pending`, receives a one-time confirm code or link, only `confirmed` contacts get alerts; SOS and share text becomes a template (no free text, link is fixed); per-user daily caps and a per-contact daily cap; atomic cap (`INSERT ... SELECT WHERE count < 3` or lock); SOS cooldown. Real UI change is limited to a "Waiting for confirmation" state on the contact card and a confirm entry (decision D2) |
| #91 | Maintained free-mail domain list (embedded file plus test), strip `+tag` before hashing, policy for unknown company names (decision D3) |
| #87 | Browse query rewrite (`LEFT JOIN LATERAL ... LIMIT 1`, keyset and `LIMIT` before ratings and counts, `accepted_count` column maintained under the existing lock, rating aggregates read from the display cache); `meetups_completed` recompute by `UNION` of two indexed counts plus partial indexes; sweep indexes `(window_end) WHERE status IN ('open','full')` and sargable starting-soon predicate; EXPLAIN before and after in the report |
| #88 | Cache-feeding events (`RatingUpdated`, request events, display, location, subscription) written to the outbox in the originating transaction; handlers idempotent; scheduled reconcile job for caches with lag metric; `CreateMeetup` no longer runs notify inline (outbox) |
| #89 | Nearby notify ordered by distance, batched token lookup, per-host meetup creation cap and rate limit |
| #90 | `review_completed_at IS NOT NULL` on public review comments; geo-visibility enforced on `GetMeetup` and `RequestToJoin` with host and participant exceptions (decision D4) |
| #93 | `/metrics` on a separate internal port (or bearer token) |
| #94 (rest) | `FLAG_SECURE` and iOS app-switcher blur on OTP, trusted contacts and SOS screens via a small platform channel; geocoder processors listed in the privacy policy text |

### Phase C, architecture, operations, observability (Plan 28C)

| Tracker | Change |
|---|---|
| #95 | CI: `govulncheck`, `gosec`, gitleaks, `flutter pub outdated` report, Dependabot (gomod, pub, actions, docker), actions pinned by SHA, `permissions: contents: read` default, base images by digest, SBOM (syft) and image scan (trivy) artifacts; deploy workflow with Workload Identity Federation (the cloud-side WIF setup is documented for Shashika to perform, not run); backup workflow moved to WIF; scripted restore drill `backend/scripts/restore-drill.sh` and runbook section |
| #95 | Migration job plus startup schema-version check (refuse to serve when the schema is older than the image expects) |
| #96 | Split `main.go` into `wiring/` plus per-module `RegisterSubscriptions`; split `meetups_postgres.go`, `meetup/service.go`, handlers and `monolithclient/meetup.go` by aggregate (requests, reviews, safety, lifecycle) to under 600 lines; split Flutter pages and `HttpAuthService` (SignIn, Verification, Safety, Account), shared HTTP helper; `select` on trust level, user id and name; router decision D5; remove `riverpod` duplicate dependency and migrate `StateProvider` before Riverpod 3 |
| #96 | ADR-001 and docs list only real modules; ADR for "one deployable, modular code boundary" or the two-service split (decision D6) |
| #88/#95 | OpenTelemetry tracing to Cloud Trace; per-poller metrics (pending, dead letters, lag, duration); alert policy YAML in `docs/deploy/alerts/`; completed-meetups poller observed |
| Testability | Tests for chats, privacy, splash; SOS failure paths; integration tests for every new query; per-package coverage printed in CI |

## Decisions needed before Phase B (defaults in brackets)

- **D1** Re-request policy after rejection: [one live request per user per meetup; a rejected user cannot re-request; a withdrawn user can].
- **D2** Trusted-contact confirmation: [SMS or email code the contact enters through a link, 24 h expiry; existing contacts grandfathered as confirmed].
- **D3** Unknown company at work-email verification: [Level 3 only after review; until then Level 2 plus an "unreviewed" flag].
- **D4** Enforce the 50 km rule on direct meetup reads and join: [yes, with host and participant exceptions].
- **D5** Flutter router: [adopt `go_router` after Phase C; until then keep imperative navigation].
- **D6** Deployment shape: [keep one Cloud Run service, `minScale: 1`, document it as a modular monolith; revisit only if the gateway needs independent scaling].

## Not in this plan

Billing and IAP verification (the module is empty; own plan), certificate pinning, biometric gate, deploying anything, creating the Android keystore or cloud IAM (instructions only).

## Order and gates

A, then B, then C. After each phase: `go vet`, `go test -race ./...`, `flutter analyze`, `flutter test`, completion report at `docs/plans/28X-completion-report.md`, tracker rows marked, vault updated. Do not start the next phase until the report is written.
