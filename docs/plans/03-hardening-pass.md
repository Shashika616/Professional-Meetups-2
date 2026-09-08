# Hardening pass — before Phase 3

Phases 1 (auth) and 2 (meetup) are functionally complete and independently
verified — every claimed fix (circuit breaker, Resend timeout, shared-secret
gRPC auth, nonce raw/hash redesign, Safety Gate, host-bypass-radius,
trust-level 4/2 gate) checked out against the actual code, not just the
completion reports.

This pass is different in kind: not "did Phase N do what it claimed" but "a
full sweep across the architecture and both modules for anything that's
cheap to fix now and expensive to fix later, regardless of whether any prior
phase plan asked for it." Four parallel audits produced the findings below.
Nothing here contradicts a prior review — this is a level up from module
correctness to production-readiness and long-term maintainability.

Every item is rated as it was found: **SHOULD FIX NOW** (compounds/gets
harder the longer it's deferred) or **MINOR** (worth doing while we're here,
low cost either way). Per your direction, fix all of them, not just the
SHOULD-FIX-NOW ones — "no known bugs, errors, gaps" was explicit. Items
marked FINE in the audits are not repeated here.

---

## A. Architecture-level (cross-cutting)

### A1. Event bus: panics not recovered, swallowed handler errors are invisible — SHOULD FIX NOW

`internal/eventbus/bus.go`'s `Publish` has no `recover()` around handler
invocation, and a handler returning an error is logged and silently dropped
— no counter, no alert, nothing distinguishing "this happened once" from
"this happens on every event." Concretely: if the nearby-notify fan-out's
handler (or the auth-side `rating-updated` consumer, or the cache upserts)
panics, that propagates up through the *publishing* request's own goroutine
(e.g. a bug in the notification handler could crash the `CreateMeetup`
request that triggered it) — a strictly worse blast radius than the
microservices version, where an equivalent bug could only affect its own
service.

Fix:
- Wrap each handler invocation in `Publish`/dispatch with its own
  `recover()`, converting a panic into a logged error, exactly like the gRPC
  and HTTP layers already do (`internal/platform/logging/recovery.go`,
  `internal/gateway/middleware/recover.go` — mirror that pattern here, don't
  invent a new one).
- Add a simple in-memory counter (or at minimum a distinguishable
  `ERROR`-level log field, e.g. `event_handler_failure_total`) incremented
  on every swallowed handler error/recovered panic, exposed once the
  `/metrics` endpoint from item D3 exists. Until then, at minimum make the
  log line `grep`-able and consistent (e.g. a fixed `event=handler_failure`
  field) so an operator can alert on log volume even before real metrics
  exist.
- Document the accepted commit-then-crash gap explicitly in
  `internal/eventbus/bus.go`'s package doc (a process crash between a
  transaction commit and its `Publish` call permanently loses that event,
  no outbox/WAL) — this is already an ADR-001 §4 accepted trade-off, but the
  package itself should say so plainly, since this is the file someone will
  read first when debugging "why didn't this user get notified."

**Scope note, so this isn't mistaken for more than it is**: the two fixes
above make failures *visible and non-fatal*. They do not add retry,
redelivery, or an outbox — that machinery was deliberately removed by
ADR-001 §4 and this pass isn't reversing that decision. The commit-then-crash
data-loss window stays as an accepted, documented trade-off, not something
closed here. See §E2b below for a related, separate problem this same
synchronous design creates once a real network call (FCM) sits behind a
handler.

### A2. Gateway↔monolith shared secret has no rotation window — SHOULD FIX NOW

`internal/platform/internalauth`'s interceptors compare against exactly one
static secret loaded at startup. Rotating it today requires restarting both
`cmd/gateway` and `cmd/monolith` with the new value at effectively the same
instant, or every call fails closed in between.

Fix: change both the server and client interceptor constructors to accept
multiple valid secrets (e.g. `INTERNAL_GRPC_SHARED_SECRET` /
`MONOLITH_SHARED_SECRET` become comma-separated lists, or add a `_PREVIOUS`
fallback variable), and `authorized()` accepts if the presented value
constant-time-matches *any* configured secret. Document the rotation
procedure (deploy with both old+new accepted → deploy the new value as the
sole outgoing secret → remove the old one from the accepted set) in
`backend/secrets/README.md`.

### A3. JWT signing key has no rotation window — SHOULD FIX NOW (same root cause as A2)

`internal/platform/jwt`'s `Signer`/`Verifier` load exactly one key pair.
Rotating the JWT signing key invalidates every outstanding access/refresh
token the instant the new key deploys — no overlap. Standard fix is a `kid`
(key ID) claim: the verifier holds a small map of `kid -> public key`
(current + N previous), the signer stamps its own `kid` into new tokens.
Add this now, before any real user base exists to be logged out by a future
rotation. Document the same deploy-old+new-then-drop-old procedure in
`backend/secrets/README.md` alongside A2's.

### A4. Rate limiter has no swap-ready seam — MINOR

`ratelimit.Limiter` is a concrete struct (private mutex+map), consumed
directly by both `handlers.WithRateLimiter` and `middleware.RateLimit`
rather than through an interface. Not urgent (correctly documented as
single-instance-only, ADR-001 §5, and the gateway is not currently run as
multiple replicas) — but extract a one-method `Limiter` interface now
(`Allow(key string, limit int, window time.Duration) (bool, error)` or
similar shape matching the current method) so a future shared-store
implementation is a new type satisfying the same interface, not a rewrite of
every call site. Cheap now; do it as part of this pass since we're already
touching this package for A1-adjacent work.

---

## B. Auth module

### B1. Refresh-token reuse isn't treated as a security signal — SHOULD FIX NOW

Rotation itself is correct (single-use, transactional, `replaced_by`
chain). But when a token that's already been rotated/revoked is presented
again — the actual signature of a stolen-and-replayed refresh token — the
system only rejects that one request. It does not revoke the rest of that
user's session family, which is the standard defensive response (this
exact request is highly likely to mean an attacker has a copy of a token
that's since been rotated by the legitimate client).

Fix: in the reuse-detected branch (`service.go`, where
`old.RevokedAt != nil || old.ReplacedBy != nil` is checked), add a call that
revokes every non-revoked refresh token for `old.UserID` — one new
repository method (`RevokeAllForUser(ctx, userID)` or similar) plus one call
site. Add a test proving: token A is used and rotated to token B: presenting
A again is rejected AND token B itself is now also revoked (the legitimate
client gets logged out too — the correct trade-off, since at this point the
server can't tell which side is the attacker).

### B2. No bounded timeout on DB calls or gRPC handlers — SHOULD FIX NOW

External HTTP calls (LinkedIn, JWKS, Twilio, Resend) all have explicit
timeouts. Nothing bounds a DB query or an in-process gRPC handler's
execution time — no `statement_timeout` on the connection, no
`context.WithTimeout` wrapping, no per-RPC deadline interceptor. In a
monolith sharing one connection pool across auth/meetup/billing, a single
stuck query (lock contention, a bad index, a slow migration running
concurrently) can hold a pooled connection indefinitely and, once the pool
is exhausted, stall unrelated modules too — a real cross-module blast-radius
risk that didn't exist when each service had its own pool.

Fix (either is acceptable, pick the one that fits the existing connection
setup better):
- Set `statement_timeout` in the Postgres connection string
  (`internal/platform/db`), a blunt but effective backstop, or
- Add a `grpc.UnaryServerInterceptor` in `cmd/monolith/main.go`'s chain that
  wraps every incoming RPC's context with a fixed deadline (e.g. 10s),
  matching the gateway's existing `ReadTimeout`/`WriteTimeout` posture.
Prefer doing both — the connection-level timeout as a hard backstop, the
per-RPC deadline as the primary, more granular control.

### B3. `auth.refresh_tokens` has no cleanup — grows forever — SHOULD FIX NOW

Every login/refresh inserts a row; nothing ever deletes one. `verification_codes`
is safe by design (unique-per-purpose upsert + delete-on-consume), but
refresh tokens accumulate indefinitely — cheap to add a sweep now, expensive
to backfill-delete from a large production table under load later.

Fix: a periodic ctx-scoped goroutine (same shape as the meetup module's
`Poller`, started from `cmd/monolith/main.go`, stopping cleanly on
shutdown) that deletes rows where `revoked_at IS NOT NULL` or
`expires_at < now() - <retention>` on a sane interval (e.g. hourly). Add a
test proving it deletes only eligible rows and leaves active tokens intact.

---

## C. Meetup module

### C1. `ValidateLatLng` doesn't reject `(0, 0)` ("null island") — MINOR

A GPS-fetch failure defaulting to `(0,0)` currently passes validation and
silently creates a meetup with bogus coordinates, breaking both the 40km
nearby-notify radius and the browse-radius filter for that meetup with no
error surfaced anywhere. One-line fix in the shared validator
(`internal/platform/geo`): reject `lat == 0 && lng == 0` explicitly (with a
clear error distinguishing it from a real out-of-range value), since (0,0)
is open ocean off the Gulf of Guinea and not a legitimate meetup location.

### C2. Lifecycle poller assumes exactly one monolith instance — SHOULD FIX NOW

Ported faithfully from the source (same limitation there), but the whole
point of this rewrite is to stay easily scalable — and horizontally scaling
`cmd/monolith` for throughput is a realistic near-term move, at which point
two pollers ticking on the same table would double-process rows within the
same window (each sees the same `status IN (...) AND window_end <= now()`
rows before either commits). The atomic `UPDATE ... RETURNING` prevents
double-*closing*, but not duplicate notification sends if both instances
race to read before either writes.

Fix: add `FOR UPDATE SKIP LOCKED` to the poller's row-selection query (or
equivalent — a `SELECT ... FOR UPDATE SKIP LOCKED` batch-claim before the
per-row close/notify), so a second concurrent poller instance naturally
skips rows the first has already claimed rather than reprocessing them.
Cheap now, while there's only one poller implementation to change; expensive
once this behavior is depended on and duplicate-notification bugs start
being triaged as one-offs.

### C3. Backfill CLIs missing — SHOULD FIX NOW

The source has `cmd/backfill-user-display-cache` and
`cmd/backfill-user-location-cache` — one-off tools to rebuild the
event-fed caches from the authoritative auth data, for exactly the scenario
where an event was lost (see A1) or a cache needs rebuilding after a schema
change. Port both as `backend/cmd/backfill-user-display-cache` and
`backend/cmd/backfill-user-location-cache`, same shape as the source
(reads directly from `auth.users`/wherever location lives, upserts into the
meetup module's cache tables, respecting the same `OccurredAt`-style
ordering guard so a backfill can't regress a row that's been updated more
recently by a live event). This is exactly the kind of tool that's cheap to
write calmly now and painful to write for the first time during an actual
incident.

### C4. Unit-test coverage gap vs. source — decide and close

Flagged at the end of Phase 2 as needing an explicit yes/no before Phase 3;
folding the answer into this pass since the instruction is now "no known
gaps." The source has ~3,900 lines of fakes-based unit tests over pure
business logic (trust gate, redaction, cursor encode/decode, validation);
this port has integration tests against real Postgres instead, which is
better coverage of the ported SQL but slower and heavier than the source's
fast unit tests for pure logic that doesn't touch the DB at all.

Fix: port fakes-based unit tests specifically for the DB-independent logic
— `trustgate.go`, `cursor.go`, `redactForViewer`, the validation functions
(capacity, lat/lng, free-text length, window ordering) — using the same
fakes/table-driven style as the source. Keep the integration tests as-is;
this is additive, not a replacement, giving fast feedback on pure-logic
regressions without needing Postgres up.

---

## D. Operational readiness

### D1. `docker-compose.yml`: monolith has no healthcheck; gateway depends on it with only `service_started` — SHOULD FIX NOW

`postgres`/`migrate` are correctly health-gated; `monolith` has no
`healthcheck:` block, and `gateway` depends on it with
`condition: service_started` — which only confirms the container process
launched, not that the gRPC server is actually listening. On a cold start or
rolling redeploy where the monolith's own startup work (DB pool warmup,
JWKS fetch) takes a moment, the gateway can come up and start accepting
traffic before the monolith is ready to serve it, causing real
early-request failures.

Fix: add a healthcheck to `monolith` — the standard approach is
implementing the gRPC health-checking protocol
(`google.golang.org/grpc/health`, `grpc_health_v1`) and using `grpc-health-probe`
(or an equivalent lightweight check) as the Docker healthcheck command;
change `gateway`'s dependency to `condition: service_healthy`. This also
gives D3's observability work a natural foundation (the same health service
can back a future `/readyz`).

### D2. No resource limits on any container — MINOR

Add `mem_limit`/`cpus` (or `deploy.resources.limits` if targeting Swarm/
Compose v3 resource syntax) to `postgres`, `monolith`, and `gateway` in
`docker-compose.yml` — even generous limits are better than none, since an
unbounded container can currently exhaust the host.

### D3. No health/readiness/metrics endpoints anywhere — SHOULD FIX NOW

Confirmed complete absence, not partial: no `/healthz`/`/readyz` on the
gateway's HTTP mux, no gRPC health service on the monolith, no `/metrics`
anywhere. Postgres's own `pg_isready` is the only health signal in the
entire stack, and it's only used for Compose dependency ordering, not
exposed for external monitoring.

Fix:
- Monolith: implement `grpc_health_v1.HealthServer`, register it alongside
  the auth/meetup services (this is also what D1 needs).
- Gateway: add a `/healthz` (process up) and `/readyz` (can reach the
  monolith — a lightweight gRPC health-check call to it) route.
- Add a `/metrics` endpoint (Prometheus text format is the standard choice
  in Go — `github.com/prometheus/client_golang`) on at least one of the two
  processes, starting with request counts/latencies per route and the A1
  event-handler-failure counter. Doesn't need to be comprehensive on day
  one; the point is that *some* metrics surface exists to build on, since
  retrofitting instrumentation into a codebase with none is much slower
  than adding a few counters to code you're already touching for this pass.

### D4. No `.dockerignore` — MINOR

Build context (`backend/`) has no `.dockerignore`, so `backend/secrets/`
(real key files present on disk, even though gitignored) and any local test
artifacts get sent into the build context and copied by each Dockerfile's
`COPY . .`, landing in an intermediate build-stage layer even though the
final distroless stage never includes them. Add
`backend/.dockerignore` excluding at minimum `secrets/`, `.git/`, `*.md`
(except where a Dockerfile needs one), and any local test/coverage output.

### D5. CI never builds the actual Docker images — MINOR

`.github/workflows/backend-ci.yml` compiles and tests Go binaries but never
runs `docker build`. A Dockerfile regression (wrong `COPY` path, wrong
`ENTRYPOINT`, a build-context assumption that breaks) would pass CI green
and only surface at actual deploy time. Add a `docker build` step (no push
needed yet, just confirm both images build) for `cmd/gateway/Dockerfile`
and `cmd/monolith/Dockerfile`.

### D6. No coverage measurement in CI — MINOR

`go test ./...` runs with no `-cover`/`-coverprofile` flag and no threshold
enforcement — coverage is entirely unmeasured, not just unenforced. Add
`-coverprofile=coverage.out` to the test step and upload it as a CI
artifact at minimum; a hard threshold gate can come later once a baseline
number exists to set the threshold from.

### D7. Monolith's `GracefulStop()` has no timeout — MINOR

Gateway's shutdown is correctly bounded (10s). Monolith's
`grpcServer.GracefulStop()` has no timeout wrapping it — a single stuck
long-lived RPC could hang shutdown indefinitely. Add a bounded wait (e.g.
`GracefulStop()` in a goroutine, `select` against a timeout, falling back to
`Stop()` if the timeout fires), matching the gateway's posture.

---

## E. Notification module — Phase 4's minimal slice, pulled forward

Added 2026-09-04 at Shashika's request, after finding that push
notifications have never worked because nothing subscribes to
`push-notification-requested` yet — Phase 4 hadn't been built. Confirmed
this is safe to pull ahead of Phase 3 (billing): `00-overview.md`'s own
dependency note for Phase 4 only ever named `auth`/`meetup`, never
`billing` — both already exist. `00-overview.md` has been updated to
record this reordering and a correction (the old Phase 4 description also
claimed it wires to "SOS's contact-alert path" — checked against the
source, and SOS has never published this event there either; that clause
was aspirational, not a gap to port, so it's dropped rather than built as
new scope here).

### E0. Human prerequisite — done as of 2026-09-05

**Resolved.** This originally said the credential had never existed in
either repo (true when written — grepped the source's entire `backend/` for
a real key and found none, same root cause as the source app's Android
push-notification bug). Shashika has since added the real
`FIREBASE_SERVICE_ACCOUNT_JSON` to the sibling microservices repo's
`backend/.env` and copied the same value into this repo's `backend/.env` —
verified by hashing both values (without printing the secret itself):
identical length, both valid-looking service-account JSON with
`private_key`/`project_id` fields present, identical SHA-256. **This means
§E/§F should be built and verified against real FCM delivery, not just the
`LoggingPushSender` fallback path** — see the updated instruction at the
end of this section.

It's consumed as the **raw JSON content**, not a file path (confirmed from
the source's `config.go`: `FirebaseServiceAccountJSON: os.Getenv("FIREBASE_SERVICE_ACCOUNT_JSON")`,
passed as `[]byte(...)` directly into the FCM client constructor — no file
read anywhere) — already true of the value now sitting in `backend/.env`,
nothing to change about the format.

**Updated instruction**: since a real key is present, run the manual
verification steps in §E4 and §F's own tests against actual FCM delivery
where the instructions call for it (real device/emulator with a registered
FCM token), not just a fake `Sender`. Still exercise the `LoggingPushSender`
path too, deliberately (e.g. by temporarily unsetting the env var in a test
run) — CI and any environment without the key still need that fallback to
work correctly, so both paths need real evidence, not just the one that's
now convenient.

### E1. Port the sender package

Port `../Professional-Meetups/backend/services/notification-dispatch/internal/notifications/{notifications.go,fcm.go,logging.go}`
into this repo as `backend/internal/modules/notification/` (no schema, no
repository — this module has no database of its own, same as the source's
`notification-dispatch` service). Port as-is:

- `Sender` interface: `SendToTokens(ctx, tokens []string, title, body string, data map[string]string) error`.
- `FCMPushSender` — FCM HTTP v1 API via `cloud.google.com/go/auth`, project
  ID auto-extracted from the service account JSON, explicit 5s HTTP
  timeout, per-token failure tolerance (one bad token doesn't block sending
  to the rest). Add `cloud.google.com/go/auth` to `go.mod` (check the
  source's `go.mod` for the exact version already proven to work).
- `LoggingPushSender` — logs the notification instead of calling FCM; the
  fallback for local dev/tests. Same never-log-a-raw-token discipline as
  the source (`send`'s doc comment there is explicit about this — preserve
  it).
- `PushNotificationRequestedPayload` (already exists,
  `internal/eventbus/events.go:114-120`) maps directly onto
  `SendToTokens`'s params (`FCMTokens`→`tokens`, `Title`, `Body`, `Data`) —
  no payload changes needed.

### E2. Wire the sender — SUPERSEDED, see §F

Originally this section wired the notification sender directly as a
`bus.Subscribe(eventbus.TopicPushNotificationRequested, ...)` handler on the
in-memory event bus. **That design is superseded by §F below**, added
2026-09-04 after working through, with Shashika, exactly what "durable
notification delivery" requires: a direct bus subscription can never survive
a process crash between a business write's commit and the `Publish` call
(the event is simply gone), and it forced the FCM call to sit inline on the
request path unless a separate worker-pool-behind-a-subscriber was bolted
on (§E2b's original point 2).

§F replaces the delivery mechanism itself (a Postgres-backed outbox +
in-process poller, owned by `meetup` since it's the sole publisher) for
this one topic — the sender construction pattern below is still exactly
right and still needed, just called from the poller in §F4 instead of a
bus handler:

Same env-var-gated constructor pattern as the source's `newPushSender` in
`notification-dispatch/cmd/server/main.go` — empty
`FIREBASE_SERVICE_ACCOUNT_JSON` means `LoggingPushSender`, non-empty means
`FCMPushSender`, log which one at startup (`slog.Info`, not a `WARN` — this
one's a normal, expected local-dev state, not a bypass).

**`push-notification-requested` is no longer published on `eventbus.Bus`
at all** — `meetup`'s call sites write an outbox row instead (§F3). Every
other topic (`user-onboarded`, `rating-updated`, the cache-upsert events,
etc.) is completely unaffected and keeps using `bus.Publish`/`bus.Subscribe`
exactly as before — this change is scoped to one topic, not a redesign of
the event bus.

### E2b. FCM calls need a circuit breaker and bounded concurrency — still required, now inside §F4

Added 2026-09-04, surfaced by Shashika asking directly whether this pass
covers retry/circuit-breaker behavior for notifications. The underlying
problem and two of the three fixes described here are still exactly right —
only *where* they live changed once §F replaced the delivery mechanism:

1. **Circuit breaker around FCM sends** — still required, unchanged. Port
   `internal/platform/breaker` (already in this codebase, restored for the
   SOS-alert path in Phase 1's fix round) around `FCMPushSender`'s per-token
   `send` call — same shape, own constants (start with the SOS breaker's
   `5 failures / 30s reset`, adjust only if FCM's real behavior under load
   warrants something different, noted explicitly if so). A degraded FCM
   should fail fast after a handful of failures, not eat a 5s timeout on
   every subsequent send. Lives inside §F4's poller loop now.
2. ~~Dispatch the notification handler asynchronously via a bounded worker
   pool behind a bus subscriber~~ — **no longer needed as its own fix**.
   §F's poller is inherently off the request path (it's driven by its own
   ticker/wake-signal, never called from the business method at all), so
   the async-dispatch problem this point solved is now solved structurally
   by the redesign rather than needing a separate worker-pool-behind-a-
   subscriber mechanism.
3. **Bounded concurrency inside `SendToTokens`/the poller's batch
   processing** — still required, same reasoning: the source's sequential
   per-token loop would otherwise serialize a large nearby-notify fan-out
   (up to 500 recipients). Replace with a small worker pool (e.g. 10-20
   concurrent sends) and an overall deadline for the batch. Keep the
   existing per-token failure tolerance (one bad token still doesn't stop
   the others) — this changes *how* they're attempted, not the
   fault-tolerance contract. Lives inside §F4.

Test (updated for the new mechanism): the breaker must trip after its
threshold and stop attempting sends until it resets (same test shape as the
SOS breaker's own cross-call-memory test); a simulated 500-recipient batch
with a slow fake sender must complete within a bounded time, not
`500 × per-call latency`. The original "business call's latency must not
depend on FCM's" test still applies but is now trivially true by
construction (the poller isn't in that call stack) — assert it anyway, as a
regression guard.

### E2c. Dead device tokens are never cleaned up — still required, now inside §F4

Added 2026-09-04, after confirming §E2b's approach against current industry
practice: FCM's HTTP v1 API returns a specific error (`status: "UNREGISTERED"`
in the JSON error body, alongside a non-200 HTTP status) when a token is
permanently dead — app uninstalled, token rotated, Firebase project
mismatch. Neither the source nor this port's plan does anything with that
signal today; `FCMPushSender.send` only checks `resp.StatusCode != http.StatusOK`
and returns a generic error, discarding the response body's actual reason.
Every dead token then gets retried on every future notification to that
user, forever, for no possible benefit.

Fix: parse the FCM error response body on a non-200 result; when the
reason is `UNREGISTERED` (or the equivalent invalid-argument case for a
malformed token), return a distinguishable sentinel/typed error from `send`,
and have the caller (the §F4 poller) delete that token from
`meetup.device_tokens` via the existing repository. Transient errors
(rate limiting, server errors, timeouts) must NOT trigger deletion — only
the specific "this token will never work again" signal should. Add a test
confirming a simulated `UNREGISTERED` response results in exactly one
`device_tokens` row deleted, and a simulated transient failure (e.g. a 500)
results in zero deletions.

This is a different kind of gap than E2b's — not a latency/availability
risk, just a permanent, silent inefficiency that gets worse over time as
more users uninstall/reinstall. Cheap now; still cheap later, but there's no
reason to leave it for a future pass once it's been named.

### E3. Config wiring (done already, code just needs to read it)

`backend/.env.example` and `backend/docker-compose.yml`'s `monolith`
service already have the placeholder comment
`# --- notification module config (Phase 4 — e.g. FIREBASE_SERVICE_ACCOUNT_JSON, add here when built) ---`.
Replace it with a real entry:

```yaml
      FIREBASE_SERVICE_ACCOUNT_JSON: ${FIREBASE_SERVICE_ACCOUNT_JSON:-}
```

(empty-string default, not `:?` required — this one's optional, same as
Twilio/Resend/Gmail). Add the matching documented, empty-by-default entry
to `.env.example` with the same "paste the whole downloaded file's content
as one line" instruction as E0 above.

### E4. Manual verification checklist — confirm each already-built trigger actually delivers

Added 2026-09-04 after Shashika asked for exactly these notification
scenarios — checked the meetup module's code and **all of them are already
implemented**, each as its own `SendPushNotification` call sitting on top of
the business logic that was already built in Phase 2. Nothing new to build
here; §F's outbox+poller is what turns these from "published, never
delivered" into real pushes. Verify each one fires once E1, E3, and §F are
wired, don't just confirm the poller compiles:

| Trigger | Notifies | Title | Where |
|---|---|---|---|
| `RequestToJoin` | host | "New join request" | `requests.go:42-47` |
| `WithdrawRequest` (covers both a still-pending request and an already-accepted participant backing out — see the function's own doc comment) | host | "Request withdrawn" | `requests.go:87-92` |
| `RespondToRequest` accept | requester | "Request accepted", then a second "Review your safety checklist" | `requests.go:126-131`, `:150-155` |
| `RespondToRequest` reject | requester | "Request declined" | `requests.go:170-175` |
| Auto-reject on capacity (fires inside an `accept` that fills the meetup) | each auto-rejected requester | "Meetup is full" | `requests.go:133-139` |
| `CancelMeetup` | every accepted requester | "Meetup cancelled" (includes host's reason) | `service.go:587-597` |
| `CloseMeetup` (manual) and the auto-close poller (time's up) — same shared helper, so both paths send identically | host **and** every accepted requester | "Meetup ended" | `service.go:468-479` (`notifyMeetupClosed`) |
| Starting-soon reminder (bonus, not asked for but already there) | host and every accepted requester | "Meetup starting soon" | `service.go:494-513` |
| Safety Gate decline | host | (declined-checklist notice) | `safety.go:150-155` |
| `meetup-created` nearby-notify fan-out | users within 40km, 24h-fresh location, host excluded | — | `service.go:630-657` (already covered before this pass) |

Test each of the first seven rows end to end with two real test accounts
(host + requester), not just the nearby-notify case that already worked —
e.g. submit a join request and confirm the host's device gets "New join
request"; accept it and confirm the requester gets both "Request accepted"
and the safety-checklist follow-up; cancel the meetup and confirm the
accepted requester gets "Meetup cancelled"; let a test meetup's window
lapse and confirm both the host and an accepted requester get "Meetup
ended" from the auto-close poller specifically (not just the manual-close
path). Report which of these were actually exercised live vs. only unit/
integration-tested against a fake `Sender`.

### E5. Tests

- Unit test `LoggingPushSender` logs without the raw token appearing
  anywhere in the log line (mirrors the source's own equivalent test if one
  exists — check `logging.go`'s neighboring `_test.go`, port it if so).
- Unit test `FCMPushSender.SendToTokens` against a mocked HTTP transport
  (same pattern the source's `fcm_test.go` uses) — confirm one failing
  token among several doesn't stop the others from being attempted, and
  confirm the returned error never contains a raw token.
- An integration-style test on the delivery wiring itself: insert an outbox
  row directly (or via a real business call) with a fake `Sender` wired into
  the poller, confirm the fake receives exactly the tokens/title/body/data
  from the payload and the row ends up `processed_at IS NOT NULL`. (Superseded
  the old in-memory-bus version of this test — see §F7 for the full set.)
- Manual verification once a real Firebase key is in `backend/.env`:
  trigger an actual `meetup-created` nearby-notify (two test accounts,
  trust level ≥ required, within 40km of each other) and confirm a real
  push arrives on a real device/emulator with the registered FCM token.

## F. Durable notification delivery — Postgres outbox (supersedes §E2's direct bus wiring)

Added 2026-09-04 at Shashika's explicit request, after walking through why
the in-memory event bus can permanently lose a `push-notification-requested`
event (a process crash between the business write's commit and the
`Publish` call) and what closing that gap actually requires. **Scoped to
this one topic, deliberately** — not a general redesign of `eventbus`, and
not a reversal of ADR-001 §4's decision to drop the outbox/Pub/Sub machinery
for everything else. See the matching ADR-001 correction
("Correction (2026-09-04, durable notification delivery)") for the
architectural reasoning; this section is the concrete build spec.

### F0. Why this topic only, not every topic

Every other event this system publishes (`user-onboarded`,
`user-profile-updated`, `user-location-updated`, `rating-updated`,
`subscription-*`) feeds an idempotent cache upsert. If one of those is lost
in the same crash window, the cache is briefly stale, it self-heals the
next time that data changes, and a backfill CLI already exists (§C3) for the
rare case it doesn't. The cost of loss is low and bounded.

A lost push notification has no such self-healing path — nothing else will
ever re-send "the host accepted your request" once that one publish is
gone, and the user's own workaround is refreshing the app and hoping to
notice the state changed. That asymmetry — one user-facing, one-shot,
no-self-heal outcome, on the one topic that also happens to require a real
third-party network call (FCM) — is exactly the profile durability
mechanisms exist for. That's the whole justification for treating this one
topic differently rather than adding this complexity everywhere.

### F1. Schema

New migration, `meetup` schema (the only publisher of this topic today —
consistent with ADR-001 §3's per-module ownership, no new schema needed):

```sql
CREATE TABLE meetup.notification_outbox (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  fcm_tokens       TEXT[] NOT NULL,
  title            TEXT NOT NULL,
  body             TEXT NOT NULL,
  data             JSONB NOT NULL DEFAULT '{}',
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  processed_at     TIMESTAMPTZ,           -- NULL = not yet delivered
  attempts         INT NOT NULL DEFAULT 0,
  next_attempt_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  dead_lettered_at TIMESTAMPTZ,
  last_error       TEXT
);
CREATE INDEX idx_notification_outbox_claimable
  ON meetup.notification_outbox (next_attempt_at)
  WHERE processed_at IS NULL AND dead_lettered_at IS NULL;
```

`processed_at IS NULL` is the entire "was this delivered" question — no
separate status enum needed, and nothing ever writes it except success
(`MarkProcessed`); a failure only ever touches `attempts`/`next_attempt_at`/
`last_error`, so "not yet delivered" is the absence of a write, not a value
the failure path has to set.

**This is a partial index — deliberately, and it's what keeps the claim
query cheap regardless of table size.** `WHERE processed_at IS NULL AND
dead_lettered_at IS NULL` in the index definition means only currently-
pending rows are ever in it; a million successfully-delivered rows sitting
in the table don't make this index bigger; they're simply not in it. The
claim query stays fast as long as the *pending* set stays small, which it
should if the poller keeps up — table growth from processed history is a
storage/VACUUM concern (§F8), not a query-latency one.

**`ClaimBatch`'s query must `ORDER BY next_attempt_at`, matching this
index — not `created_at`.** A fresh row's `next_attempt_at` defaults to its
insertion time (see the column default above), so this is already
close-enough-to-FIFO for the common case, and it's the *correct* priority
regardless: a row that's failed once and is backing off should rank behind
fresh rows, not compete with them on original insertion time. Ordering by
anything the index doesn't cover forces a separate sort step that gets more
expensive as the pending set grows — exactly the scaling problem to avoid
here. `ClaimBatch`'s `SELECT` should also list explicit columns
(`id, fcm_tokens, title, body, data, attempts`), not `*` — narrow enough
that it's not a performance issue on its own, but no reason to invite one
by convention.

Matching `.down.sql`: `DROP TABLE meetup.notification_outbox;` (or folded
into the schema's existing `DROP SCHEMA ... CASCADE`, same pattern as every
other table here).

### F2. Generic poller package

New `internal/platform/outbox` — written once, reusable by any future
module that wants this same durability guarantee for one of its own
topics (auth or billing, later, without re-inventing this). Shape:

```go
type Row struct {
    ID            string
    Payload       []byte // JSON-encoded, module-defined shape
    Attempts      int
}

type Store interface {
    // ClaimBatch selects up to limit unprocessed, due rows and locks them
    // (FOR UPDATE SKIP LOCKED) for the duration of the caller's processing —
    // same concurrency-safety pattern already used by the lifecycle poller,
    // so a second poller instance (or a future horizontally-scaled
    // monolith) can never double-process a row.
    ClaimBatch(ctx context.Context, limit int) ([]Row, error)
    MarkProcessed(ctx context.Context, id string) error
    MarkFailed(ctx context.Context, id string, nextAttemptAt time.Time, lastErr string) error
    MarkDeadLettered(ctx context.Context, id string, lastErr string) error
}

type Poller struct { /* store Store; process func(ctx, Row) error; ... */ }

func New(store Store, process func(ctx context.Context, r Row) error, opts ...Option) *Poller
func (p *Poller) Run(ctx context.Context)  // blocks until ctx is cancelled, same shape as meetup.Poller.Run
func (p *Poller) Wake()                    // non-blocking nudge — see F5
```

`process` is where §E2b's breaker and bounded-concurrency logic and §E2c's
dead-token cleanup actually live, for the notification case specifically —
`internal/platform/outbox` itself knows nothing about FCM, tokens, or
notifications; it's purely the generic claim/retry/backoff/dead-letter
machinery.

Backoff: something simple and standard is enough here — e.g.
`min(2^attempts * baseDelay, maxDelay)` with a fixed cap
(`maxAttempts = 10` before `MarkDeadLettered`, consistent with "give up
eventually and surface it, don't retry forever").

### F3. `meetup`'s publish call sites change from bus.Publish to an outbox insert

Every one of the six call sites in `requests.go`/`service.go` that
currently call `s.notifications.SendPushNotification(Batch)` keep their
exact same signatures and call shape from the business logic's point of
view — only what's *underneath* that interface changes. Instead of
resolving tokens and calling `bus.Publish(ctx, eventbus.TopicPushNotificationRequested, payload)`,
the implementation now does `INSERT INTO meetup.notification_outbox (...)`
**in the same transaction as the business write** (this is the entire
point — it's now genuinely atomic with the accept/reject/cancel/close, not
"committed, then a best-effort publish after"). After the transaction
commits, call the new poller's `Wake()` (§F5) — non-blocking, just a nudge.

No changes needed to `requests.go`/`service.go`'s own call sites beyond
what's already there; this is entirely inside the `notifications.Sender`
implementation the meetup module already codes against.

### F4. The poller itself (lives in the new `internal/modules/notification` package)

Constructed in `cmd/monolith/main.go` alongside the sender from §E1/§E2,
using `internal/platform/outbox.New(store, process)` where `process`:

1. Attempts `sender.SendToTokens(ctx, row.FCMTokens, row.Title, row.Body, row.Data)`,
   itself wrapped in the §E2b circuit breaker and using §E2b's bounded
   concurrency for a batch (a row with many tokens still fans out
   internally, just now from inside the poller's processing rather than a
   bus handler).
2. On success: `MarkProcessed`.
3. On a per-token `UNREGISTERED` response (§E2c): delete that token from
   `meetup.device_tokens`, and don't let that count as the whole row
   failing if at least one other token in the same row succeeded.
4. On any other failure: `MarkFailed` with backoff, or `MarkDeadLettered`
   past the attempt ceiling.

`Run` starts as a goroutine from `cmd/monolith/main.go`, ctx-scoped exactly
like the meetup lifecycle poller (stops cleanly on SIGTERM).

### F5. Wake-signal optimization — near-zero latency without giving up the safety-net tick

The reason this doesn't have to feel like "polling" in the slow, laggy
sense: because the writer (`meetup`'s business methods) and the poller
(`internal/modules/notification`) share the same process, a business write
can nudge the poller the instant it commits, instead of waiting for the
next tick. `Wake()` sends on a buffered, non-blocking channel (`select`
with a `default` — a dropped nudge is fine, the tick below still catches
it): the poller's `Run` loop selects on both the wake channel and a regular
ticker (e.g. every 2s), so the common case gets near-immediate delivery and
the tick is purely the safety net for a dropped/coalesced wake, a
backoff-delayed retry becoming due, or rows that piled up while the process
was down.

### F6. At-least-once, not exactly-once — document this trade-off explicitly

If the process crashes after `sender.SendToTokens` succeeds but before the
`MarkProcessed` update commits, that row is retried on the next claim and
the user gets a duplicate notification. This is the accepted trade-off, the
same one every outbox-style system makes — correct for this use case (a
rare duplicate "your request was accepted" push is a minor annoyance, not a
correctness bug, unlike a duplicate payment) — no idempotency key is being
added to close this, and that absence should be a deliberate, documented
choice, not an oversight. State this explicitly in the package doc comment
for `internal/modules/notification`, next to `internal/eventbus/bus.go`'s
equivalent note from §A1.

### F7. Tests

- Schema: `meetup.notification_outbox` insert happens in the same
  transaction as a business write — test a simulated failure *after* the
  outbox insert but *before* the business write's own commit rolls back
  both together (proving genuine atomicity, not just "usually happens
  together").
- `ClaimBatch`'s `FOR UPDATE SKIP LOCKED`: two concurrent callers claiming
  from the same pending set must never receive overlapping rows — same
  test shape as required for the lifecycle poller's own concurrency fix
  (§C2).
- Backoff: a failed row's `next_attempt_at` moves forward correctly and
  isn't claimable again until it's due; after `maxAttempts`, the row is
  `dead_lettered_at`-marked and never claimed again.
- Wake-signal: a business write followed immediately by an assertion that
  the notification was sent, well before the safety-net tick interval would
  have fired — proving the wake path is what delivered it, not the tick.
- Crash-recovery simulation: a row claimed (locked) by a caller that never
  calls `MarkProcessed`/`MarkFailed` (simulating a crash mid-processing)
  must become claimable again once that transaction/connection ends —
  proving Postgres's own lock release is what recovers this, not anything
  this code has to do explicitly.
- §E2b's breaker/bounded-concurrency tests and §E2c's dead-token test, all
  still required, now exercised through the poller's `process` function
  instead of a bus handler.
- §F8's retention job: a simulated backlog of old processed and old
  dead-lettered rows must be deleted only once past their respective
  retention windows, and a fresh row (either state) must survive a run of
  the job.

### F8. Retention — delete old processed/dead-lettered rows

The partial index (§F1) already means old rows don't slow down the claim
query — this is about disk/VACUUM hygiene, not query correctness, but it's
still needed: an unbounded table is cheap to add cleanup for now and
expensive to backfill-delete from later, same lesson as §B3's
`auth.refresh_tokens` sweep.

Add a periodic ctx-scoped goroutine (same shape as §B3's sweep and the
meetup lifecycle poller — started from `cmd/monolith/main.go`, stops
cleanly on SIGTERM), running on a coarse interval (e.g. hourly):

- Delete rows where `processed_at IS NOT NULL AND processed_at < now() - INTERVAL '7 days'`
  — they've done their job; a week is generous margin for any debugging
  that needs a recently-delivered row.
- Delete rows where `dead_lettered_at IS NOT NULL AND dead_lettered_at < now() - INTERVAL '30 days'`
  — kept longer than successes, deliberately: a dead-lettered row is a
  real, permanent delivery failure worth someone noticing and investigating
  before the evidence disappears.
- Batch the deletes (e.g. `DELETE ... WHERE id IN (SELECT id FROM ... LIMIT 1000)`,
  looped until no rows match) rather than one unbounded `DELETE` — protects
  against a long lock/transaction if this job is ever turned on after a
  backlog has already accumulated (e.g. after being disabled for a while,
  or on first deploy against a table that was seeded some other way).

## Explicitly not changing in this pass

- **Items already rated FINE** by the audits (config validation, error
  handling/info leakage, panic recovery at the RPC/HTTP layer, module
  boundary purity, migration reversibility of what exists today, structured
  logging consistency, secrets never committed, pagination/cursor
  correctness, concurrency handling for capacity/rating/close races) — no
  changes needed, don't touch what isn't broken.
- **Known, already-accepted architectural trade-offs restated by the
  audits, not new findings**: `push-notification-requested` having no
  subscriber until Phase 4, `subscription-*` having no publisher until
  Phase 3, and `meetup-request-created/-accepted/-rejected` having zero
  consumers (a gap ported as-is from the source, not introduced here) —
  these are intentional phase boundaries, not bugs, and stay as documented
  gaps for Phase 3/4 to close, not this pass.

## When done

Same bar as every phase: real `go build ./...` / `go vet ./...` /
`golangci-lint run ./...` / `go test -race ./...` output, not a claim. Each
fix above needs its own test proving the specific failure mode it closes
(e.g. B1's test needs to show the legitimate rotated token B also gets
revoked, not just that reused token A is rejected; C2's fix needs a test
with two concurrent poller ticks against overlapping rows, not just a single
poller run). Report per item, in the same A/B/C/D/E/F grouping as this
document, noting anything that turned up a reason to deviate from what's
described here — same standing instruction as every phase before this one.

For §E specifically: a real `FIREBASE_SERVICE_ACCOUNT_JSON` is now present
in `backend/.env` (§E0) — report real FCM delivery evidence (an actual push
received on a device/emulator), not just that the logging fallback ran.
Also confirm the fallback path still works correctly when the env var is
unset (temporarily, for that one test) — both paths need real evidence.
Also confirm §F is what actually delivers now, not a direct bus subscriber
— the outbox insert must be in the same transaction as the business write
(test the rollback-together case from §F7), `ClaimBatch`'s
`FOR UPDATE SKIP LOCKED` must be proven safe under concurrent claimers, and
the wake-signal path must be shown to deliver faster than the safety-net
tick interval. Confirm §E2b's breaker and bounded-concurrency fixes and
§E2c's dead-token cleanup explicitly, now as they run inside §F4's `process`
function — a breaker with a real cross-call-trip test, bounded concurrency
in the batch send (a 500-recipient batch against a slow fake completing in
bounded time, not linearly with recipient count), and a simulated
`UNREGISTERED` FCM response deleting exactly the one dead token while a
simulated transient failure deletes none.
