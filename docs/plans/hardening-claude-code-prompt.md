# Claude Code prompt — hardening pass + notification module (Phase 4, pulled forward)

You're working in `/Users/as/Documents/Professional Meetups/Professional-Meetups-Monolith`.
Phases 1 (auth) and 2 (meetup) are built and independently verified — every
claimed fix in both completion reports was checked against the actual code,
not just trusted. This is a different kind of pass: not "did the last phase
do what it claimed" but a full sweep for anything that's cheap to fix now
and expensive to fix later, plus one genuinely new feature slice (real push
notifications) pulled forward from its originally-planned phase.

## Read first, in this order

1. `docs/plans/03-hardening-pass.md` in full — this is the actual spec for
   everything in this prompt, sections A through F. This prompt summarizes
   it; that document has the real detail, file:line citations, and reasoning
   for every item. Don't work from this prompt alone. **§E2/§E2b's original
   "wire a bus.Subscribe handler" design is superseded by §F** (added last,
   after §E) — read §F before implementing §E's wiring, not after, so you
   don't build the superseded version first.
2. `docs/decisions/adr-001-modular-monolith-architecture.md`, including both
   its "Corrections" section and the later "Correction (2026-09-04, durable
   notification delivery)" section.
3. `docs/plans/00-overview.md`'s Quality Bar section, and its 2026-09-04
   note on why Phase 4 is being pulled ahead of Phase 3.
4. `TESTING-NOTES.md` at the repo root (new) — the gated OTP bypass added
   just before this pass; don't touch it or its gating logic as part of this
   work, it's already done and unrelated to anything below.

## What this pass covers

Six sections from `03-hardening-pass.md` (A through F), fix **all** of
them, not just the ones marked SHOULD-FIX-NOW — "no known bugs, errors,
gaps" was explicit from Shashika, so MINOR items get fixed too, not
deferred:

- **§A — architecture-level**: event bus panic recovery + observability on
  swallowed handler errors; rotatable gateway↔monolith shared secret (accept
  multiple valid secrets); rotatable JWT signing key (`kid`-based, current +
  previous); extract a `Limiter` interface in `internal/platform/ratelimit`
  for future swap-readiness.
- **§B — auth module**: refresh-token reuse detection should revoke the
  rest of that user's session family, not just reject the one request;
  bound every DB call/gRPC handler with a timeout (statement_timeout and/or
  a per-RPC deadline interceptor); a periodic sweep to delete expired/revoked
  `auth.refresh_tokens` rows (they currently accumulate forever).
- **§C — meetup module**: reject `(0,0)` "null island" coordinates in
  `ValidateLatLng`; add `FOR UPDATE SKIP LOCKED` to the lifecycle poller's
  row-selection so a future second monolith instance can't double-process;
  port the two missing backfill CLIs
  (`cmd/backfill-user-display-cache`, `cmd/backfill-user-location-cache`);
  port fast fakes-based unit tests for the DB-independent logic
  (`trustgate.go`, `cursor.go`, `redactForViewer`, validation functions) —
  additive to the existing integration tests, not a replacement.
- **§D — operational readiness**: a gRPC health-check service on the
  monolith (`grpc_health_v1`) + a compose healthcheck for it + change
  gateway's dependency to `service_healthy`; `/healthz`+`/readyz` on the
  gateway; a basic `/metrics` Prometheus endpoint (request counts/latencies
  per route, plus §A's event-handler-failure counter); resource limits in
  `docker-compose.yml`; a `.dockerignore`; a `docker build` step in CI for
  both images; a coverage flag/artifact in CI; a bounded timeout around the
  monolith's `GracefulStop()`.
- **§E — notification module (Phase 4's minimal slice, pulled forward)**:
  port `Sender`/`FCMPushSender`/`LoggingPushSender` from the source's
  `services/notification-dispatch/internal/notifications` into
  `internal/modules/notification`. This makes every one of `meetup`'s
  already-built publish call sites (Phase 2) start actually delivering — no
  changes needed to those call sites' own signatures. This includes every
  notification trigger Shashika specifically asked for (new join request →
  host, accept/reject → requester, withdraw → host, cancel → accepted
  requesters, auto-close/manual-close → host and all accepted requesters) —
  **all of it was already built in Phase 2**, just never delivered. §E4 in
  `03-hardening-pass.md` has the full table with file:line for each one and
  a manual verification checklist — work through it explicitly, don't just
  confirm the delivery mechanism compiles. **Do not wire this via
  `bus.Subscribe` — that design is superseded by §F below**, built from the
  start against the outbox.
- **§F — durable delivery via a Postgres outbox (supersedes §E2's original
  bus-subscriber wiring, don't skip straight to a bus handler)**: added
  after Shashika asked directly for durability. `meetup`'s
  `SendPushNotification(Batch)` implementation writes to a new
  `meetup.notification_outbox` table in the same transaction as the
  business write it accompanies, instead of publishing on `eventbus.Bus` —
  this is what makes the write and the notification genuinely atomic (today,
  a crash between commit and publish loses the event forever; this closes
  that). A new generic `internal/platform/outbox` package (a `Poller` with
  `ClaimBatch`/`FOR UPDATE SKIP LOCKED`, retry with backoff, dead-letter
  past a ceiling — same concurrency-safety shape as the lifecycle poller)
  drives delivery, woken immediately after each commit via a non-blocking
  channel nudge, with a periodic tick as the safety net. §E2b's circuit
  breaker and bounded-concurrency requirements and §E2c's dead-token
  cleanup **still apply, unchanged in substance** — they now live inside
  this poller's per-row processing function instead of a bus handler. Full
  schema, package shape, and required tests (including a concurrent-claim
  test and a same-transaction-atomicity test) are in
  `03-hardening-pass.md` §F, with the architectural reasoning for why this
  is scoped to this one topic (not every event topic) in ADR-001's matching
  correction section. Every other event topic in this system
  (`user-onboarded`, `rating-updated`, the cache upserts, etc.) is
  completely unaffected — still `eventbus.Bus`, still synchronous, no
  changes needed there. The claim index is partial and must be queried with
  `ORDER BY next_attempt_at` (matching the index — not `created_at`, which
  would force an unindexed sort as the pending set grows) — §F1 has the
  exact index definition, don't deviate from it. §F8 adds a retention job
  (delete processed rows after 7 days, dead-lettered after 30, batched) —
  don't skip this; an unbounded outbox table is the same class of mistake
  as §B3's `auth.refresh_tokens` gap this pass already fixes elsewhere.

## §E's human prerequisite is done — a real key is already in `backend/.env`

Updated 2026-09-05: a real `FIREBASE_SERVICE_ACCOUNT_JSON` is now present in
this repo's `backend/.env` (copied from the sibling microservices repo's own
working value — verified by hash comparison, not just assumed). **This
means §E/§F must be verified against real FCM delivery**, not just the
`LoggingPushSender` fallback: run the manual checks in §E4 and §F's tests
against an actual device/emulator with a registered FCM token and report
the real result. Separately, also confirm the fallback path still works
correctly with the env var temporarily unset for one test run — CI and any
environment without the key still depend on that path, so both need real
evidence in your completion report, not just the one that's now easy to
exercise.

## Ground rules (same as every phase before this one)

- Real Go project — actually run `go build ./...` / `go vet ./...` /
  `golangci-lint run ./...` / `go test -race ./...`, real output, not a
  claim.
- Every fix needs a test proving the specific failure mode it closes, not
  just "it compiles." Two examples where this matters most: the refresh-token
  reuse fix (§B1) needs a test showing the *other*, legitimately-rotated
  token also gets revoked, not just that the replayed one is rejected; the
  lifecycle poller fix (§C2) needs a test with two concurrent poller ticks
  racing over overlapping rows, not a single poller run.
- No client-side-only validation, no unparameterized SQL, no
  authorization decision sourced from anything but the verified JWT context
  — same standing rules as every phase.
- If anything in `03-hardening-pass.md` turns out to be wrong, ambiguous, or
  based on a stale assumption once you're actually in the code, say so
  explicitly and propose the correction — same as Phase 2 correctly did for
  three premises that turned out to already be fixed upstream. Don't
  silently work around a wrong instruction.
- Nothing in `docs/plans/00-overview.md`'s "Explicitly not changing in this
  pass" list needs touching (things already rated FINE by the audits, and
  the known Phase-3/Phase-4-boundary event topics that still have zero
  consumers by design — `meetup-request-created/-accepted/-rejected`,
  `subscription-*`). Don't "fix" those; they're not gaps in this pass's
  scope.

## When done

Report per `03-hardening-pass.md`'s own "When done" section: real
build/vet/lint/test output; each fix's specific proof test; §F's outbox
proven atomic-with-the-business-write and safe under concurrent claimers,
not just "the poller runs"; §E's explicit statement on whether real
Firebase delivery was verified or only the logging fallback; anything you
found that contradicts this prompt or that document, called out rather than
silently worked around. After this is confirmed done and reviewed, Phase 3
(billing) resumes as originally planned.
