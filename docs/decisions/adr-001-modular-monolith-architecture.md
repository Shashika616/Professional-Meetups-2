# ADR-001 — Modular Monolith Backend Architecture

**Status**: Accepted
**Date**: 2026-09-04
**Context**: parallel-track redesign, requested directly by Shashika. Does not
replace or modify `../Professional-Meetups` (the existing 5-service
microservices backend) — that repo keeps running exactly as it is. This ADR
governs a second, independent implementation of the same product, in this repo.

## Why

The microservices backend (auth, meetup, billing, notification-dispatch,
gateway — 5 independently deployed Go services, 3 separate Postgres databases,
Redis, Pub/Sub) is real infrastructure overhead for a product at this stage.
Shashika wants a simpler operational shape — one backend deployable plus a
thin gateway, one database, no Redis, no message broker — **without giving up
the option to re-split a module back into its own service later** if/when
scale actually demands it. Every decision below is chosen with that
re-extraction path in mind, not just "make it smaller."

## Decisions

### 1. Two deployables, not one

The gateway (`cmd/gateway`) and the monolith (`cmd/monolith`) stay **separate
binaries/processes**, exactly as requested. The gateway still receives REST
from the frontend and still talks to the backend over gRPC — that hasn't
changed and isn't simplified away. What's simplified is that it now has one
gRPC target instead of three (today: `AUTH_SERVICE_ADDR`,
`MEETUP_SERVICE_ADDR`, `BILLING_SERVICE_ADDR`, each independently optional/
required per `services/gateway/internal/config/config.go`). "In-process"
below describes what happens *inside* the monolith between its modules — it
never describes the gateway-to-monolith hop.

### 2. Module boundaries mirror today's actual services, not new ones

Four modules, matching the four backend deployables that exist today (SOS/
trusted-contacts is **not** a fifth module — it's already part of the `auth`
service today, both as tables in `auth_db` and as `AuthService` RPCs
(`AddTrustedContact`, `TriggerSOS`, etc.) — it stays a sub-package of the
`auth` module here, `internal/modules/auth/sos/`, not a sibling top-level
module):

- `internal/modules/auth` — identity, verification (phone/email/corporate),
  federated sign-in (Apple/Google/LinkedIn), sessions/refresh tokens, profile,
  the rating-average cache, trusted contacts + SOS.
- `internal/modules/meetup` — scheduling, lifecycle/auto-close, requests,
  safety gate, ratings, geo-visibility, device tokens, the three read-model
  caches (`user_display_cache`, `user_location_cache`, `subscription_cache`).
- `internal/modules/billing` — subscriptions, Apple/Google purchase
  verification, webhook handling.
- `internal/modules/notification` — owns no schema at all (today's
  notification-dispatch has no database either) — just the `Sender`
  interface (FCM or logging fallback) and the handler that reacts to a
  `push-notification-requested` event on the bus.

Each module exposes exactly one Go interface (its own `Service` type) to the
rest of the monolith — no module reaches into another module's repository or
SQL directly, ever. This is the single rule that keeps re-extraction cheap:
today a module boundary is a network/gRPC boundary; here it's a Go package
boundary with one entry point. Turning it back into a network boundary later
means writing a gRPC server around that one existing interface, not
untangling call sites scattered across the codebase.

### 3. One Postgres database, one schema per module, no cross-schema foreign keys

All tables move into one database, but under separate Postgres **schemas**:
`auth.*`, `meetup.*`, `billing.*` (`notification` needs no schema — it has no
tables). Every column that is today a "logical FK with no real constraint"
across service databases (`meetups.host_user_id`, `meetup_requests
.requester_id`, `subscriptions.user_id`, etc. — the full list is in the
inventory this ADR is grounded on) **stays exactly that way here**: a plain
UUID column, no `REFERENCES auth.users(id)`, even though a real FK is now
physically possible in one database. Adding those FKs would read as a small
correctness improvement today and would be exactly the coupling that makes a
module impossible to re-extract later without a data-migration project. This
is a deliberate, explicit trade: no referential-integrity assist from
Postgres, in exchange for keeping the door open. Authorization/identity
integrity keeps coming from the JWT-derived caller ID at the module interface,
same as today — never from a DB constraint.

**The three read-model caches** (`user_display_cache`, `user_location_cache`,
`subscription_cache` in meetup, and auth's own `rating_average`/`rating_count`
cache columns on `users`) existed specifically because cross-database reads
were impossible. In one database they *could* be replaced with a real
cross-schema read — but that would reintroduce the exact coupling being
avoided. **Decision: keep the caches, keep them fed the same way (an event,
now delivered by the in-process bus instead of Pub/Sub)** — same
eventual-consistency model as today, same idempotent-upsert-with-timestamp-
guard pattern, just a cheaper transport underneath. Don't collapse them into
a live join just because the same database makes it possible.

### 4. In-process event bus, zero extra infrastructure

Cross-module event flows (`user-onboarded`, `user-profile-updated`,
`rating-updated`, `user-location-updated`, `meetup-created`,
`push-notification-requested`, `subscription-activated`,
`subscription-deactivated` — full detail in the inventory) move to
`internal/eventbus`: a `Publish(ctx, topic, payload)` / `Subscribe(topic,
handler)` interface, implemented as an in-memory dispatcher. No Pub/Sub
emulator, no broker, no extra container. **Deploying this system is exactly
two things: the gateway, and the monolith** — nothing else, per Shashika's
explicit ask.

This means the transactional outbox pattern (`shared/outbox`, each service's
own `outbox_events` table + poll-and-publish relay) is **not carried over**.
It existed to make publish-then-network-call safe when the publish and the
business write could not share a transaction (different process, and the
network call to Pub/Sub could fail independently of the DB commit). In the
monolith, a module's business write and its event publish **do share a
transaction** (same process, same database) — so the correct replacement is:
commit the business write, then call `bus.Publish` synchronously in the same
request, with the handler(s) it invokes wrapped in their own error handling
(a failed in-process handler must not roll back or fail the original
request — same "best-effort" posture the old async relay had, just without
a poll loop or a breaker in front of a network call that can no longer fail
that way). Concretely: keep the **idempotent-upsert-with-timestamp-guard**
logic in every consumer (still real insurance against a handler running
twice, e.g. a retry higher up), drop the outbox table, the relay, and the
circuit breaker around it — `shared/breaker` and `shared/outbox` are not
carried into this repo.

The two same-service event flows with **zero consumers today**
(`meetup-request-created/accepted/rejected` — see the inventory) are ported
as-is (published, unconsumed) rather than silently dropped — they're a
tracked gap in the original backend, not a decision this ADR should quietly
make differently.

### 5. Redis removed; rate limiting moves in-memory, in the gateway

Redis's only job in this whole system today is gateway rate limiting
(`REDIS_ADDR`, required gateway config) — nothing else depends on it. The
existing algorithm (`services/gateway/internal/middleware/ratelimit.go`) is
already a plain fixed-window counter (`INCR` + conditional `EXPIRE`, atomic
via a Lua script) — nothing about it depends on Redis specifically beyond
atomicity of increment-and-expire, which an in-memory map with a mutex (or
per-key atomics) provides just as well within one process. Port the exact
same four key shapes and limits as-is (IP+path 20/min global; email-keyed
20/min on the two email auth routes; target-keyed 5/hour on the three OTP-
start routes; user-keyed 10/hour CreateMeetup, 5/hour SOS trigger, 5/hour
VerifyPurchase) — same numbers, same routes, same 429 response shape,
different backing store.

**Explicit, accepted trade-off**: an in-memory limiter is only correct for a
*single gateway instance*. If the gateway is ever horizontally scaled behind
a load balancer, each replica enforces its own independent limit — a user
could get up to (replica count × limit) instead of the stated limit. Today's
Redis-backed limiter was correct across replicas; this one isn't. Accepted
because a single-gateway-instance deployment is the plan for now; revisit
(bring back a shared store, just for rate limiting, if the gateway is ever
scaled out) rather than silently re-adding Redis for this reason without
saying so.

### 6. JWT signing moves into the gateway

Today: `shared/jwt`'s `Signer` (holds the RSA private key) lives only in the
auth service; every other service and the gateway hold only the public key
(`Verifier`). Here: **the gateway holds the private key and does the
signing.** The monolith's auth module authenticates the request (validates
credentials/OTP/federated-identity token, resolves or creates the user) and
returns identity facts (`user_id`, `trust_level`, `is_new_user`, profile
fields) over gRPC — it does not return a pre-signed token the way today's
`SessionResponse` does. The gateway takes that response and calls its own
`jwt.Sign()` to produce the access/refresh tokens returned to the client.

This is a real, deliberate contract change from today's `auth.proto`
`SessionResponse` (which carries `access_token`/`refresh_token` fields
populated by the auth service itself) — the monolith's equivalent internal
response type drops those two fields, the gateway adds them back after
signing. Every route that returns a session (LinkedIn callback, federated
signup, email signup/login, refresh, phone/personal-email verification
completion, profile setup) is affected identically; there's no route where
the old shape needs to be preserved. `RefreshSession` in particular needs the
gateway, not the monolith, doing the actual re-signing — the monolith's auth
module still owns validating/rotating the refresh-token row in
`auth.refresh_tokens`, it just hands back "here's the user this refresh token
belongs to, here's its new replacement token row" rather than a signed JWT.

Rationale: the gateway is the single entry point and already terminates
every client connection — it's the natural place to centralize a
cross-cutting concern like this, and it means the monolith binary itself
never needs to hold the private key at all, which is a smaller blast radius
if that binary is ever compromised.

### 7. Shared packages — what's reused, what's dropped

From `shared/` in the microservices repo:

- **`jwt/`** — reused, but collapsed: one process (the gateway) now needs
  both the signer and the verifier; the monolith needs neither (see #6).
- **`apperror/`** — reused. `grpc.go`'s gRPC-status mapping stays relevant
  (gateway-to-monolith is still gRPC, per #1); nothing here needs to change.
- **`geo/`**, **`geocoding/`** — reused as-is, no changes; both are already
  fully generic with zero DB/service coupling.
- **`logging/`** — reused as-is (structured logging, request ID
  propagation, panic recovery); the gRPC interceptor half still applies
  since gateway-to-monolith stays gRPC.
- **`breaker/`**, **`outbox/`** — **not carried over** (see #4 — the failure
  mode they existed to guard against, a network publish failing
  independently of a DB commit, doesn't exist for an in-process event bus).
- **`events/` (payload structs)** — reused as plain Go structs/function
  parameters for `bus.Publish`/`Subscribe` calls; they stop being
  JSON-serialized wire payloads (no longer crossing a process boundary) but
  keep the same job of pinning down a stable shape between publisher and
  subscriber code.
- **`proto/` (generated auth/meetup/billing bindings)** — reused for the
  gateway↔monolith gRPC contract (adjusted per #6 for the session-response
  field removal), not reused for anything module-to-module inside the
  monolith (those calls are direct Go interface calls, no protobuf involved).

### 8. What's explicitly out of scope for this ADR

This ADR fixes the architecture; it does not re-decide any product/business
rule already settled in the microservices repo's own ADRs (trust levels,
verification requirements, the 40km radius, rate-limit numbers, Safety Gate
behavior, etc.). Every business rule ports as-is unless a build-phase plan
says otherwise for a concrete infrastructure reason (like the session-token
field removal above).

## Consequences

- **Positive**: one database to operate/back up, one backend binary to
  deploy/scale, no Redis, no Pub/Sub/emulator, no outbox-relay
  poll-loop/circuit-breaker machinery to reason about. Faster local dev
  (fewer containers). All cross-cutting auth concerns (JWT, rate limiting)
  live in one place (the gateway) instead of split across services.
- **Negative / accepted trade-offs**: no DB-level referential integrity
  across module boundaries (by design, #3); in-memory rate limiting isn't
  replica-safe if the gateway is ever scaled horizontally (#5); losing the
  transactional-outbox's retry/backoff/circuit-breaker safety net around
  event delivery — an in-process handler failure is now a same-request
  concern to handle deliberately (log-and-continue, matching today's
  "best-effort, never fail the request" posture for these same flows),
  not a background-relay concern with its own retry loop.
- **What stays easy to re-extract later**: any of the four modules, given
  rule #2 (one interface per module, no cross-module SQL) and rule #3 (no
  cross-schema FKs) — re-extraction means standing the module's schema up in
  its own database, writing a gRPC server around its existing interface, and
  swapping its event-bus `Subscribe` calls for real Pub/Sub consumers. The
  business logic inside the module doesn't need to change.

## Corrections (2026-09-04, after Phase 1 review)

Phase 1 surfaced two places where this ADR's own wording was imprecise
enough to cause a real ambiguity, plus one gap this ADR never addressed at
all. All three are corrected here rather than silently rewritten above, per
this project's own convention (see the sibling repo's ADR correction
sections) — the original reasoning stays visible, the correction is
additive.

**§6 overstated what the gateway signs.** "The gateway itself calls
`jwt.Sign()` to produce the access/refresh tokens" was wrong for the refresh
token specifically. Only the **access token** is a signed JWT — that's the
only thing that needed relocating to the gateway, because it's the only
thing that's a stateless credential mintable from a signing key alone. The
**refresh token** was never a JWT in this system, source or monolith: it's
32 random bytes, hex-encoded, with only its SHA-256 hash persisted — an
opaque, revocable, DB-backed credential (`auth.refresh_tokens`, rotation via
`replaced_by`). Generating and persisting it has to happen wherever the
database lives, which is the monolith, not the gateway (the gateway has no
DB connection anywhere in this design). The monolith returns the raw
refresh-token value to the gateway over gRPC; the gateway passes it through
to the client unchanged, alongside the access token it just signed itself.
This is what Phase 1 actually built, and it's correct — the ADR's own prose
was the thing that needed fixing, not the code.

**§7's breaker removal was scoped too broadly.** The source's `shared/
breaker` has (at least) two independent call sites, and this ADR's reasoning
only actually applies to one of them. The outbox relay's use of it
(protecting a Pub/Sub publish call that could fail independently of the
paired DB commit) is correctly gone — that failure mode doesn't exist for
an in-process event bus, per §4. But the SOS-alert send path's per-channel
breaker (`sosBreakerFailureThreshold`/`sosBreakerResetTimeout` in the
source) protects against something completely unrelated to events or
outboxes: a slow or down third-party vendor (Twilio, Resend), called
synchronously, on an **emergency** path. That failure mode is identical in
this repo — Twilio/Resend are still real external HTTP calls here, made
exactly the same way. Phase 1 dropped this breaker too, reading "no
breaker" as a blanket rule; it wasn't meant to be one. **Correction: the
per-channel SOS-alert breaker should be ported**, using the same
threshold/reset-timeout values as the source, so a sustained Twilio or
Resend outage degrades gracefully (fail fast after repeated failures)
instead of every single `TriggerSOS` call paying full retry-and-timeout cost
against a channel that's already known to be down. See
`docs/plans/phase1-fixes-breaker-timeout-grpc-auth.md` for the concrete
fix.

**New: the gateway-to-monolith gRPC surface has no authentication of its
own.** Not something this ADR considered originally. Every method on the
monolith's gRPC service trusts its caller's identity fields (`user_id`,
etc.) without independently verifying them — safe only because, today,
nothing but the gateway can reach the monolith's gRPC port, which is a
Docker-network-isolation assumption, not something the code itself enforces.
This exact gap exists in the source system too (its services trust their
callers' identity fields the same way, protected by the same kind of
network-topology assumption) — so this isn't a regression the port
introduced, but it's also not something to carry forward silently now that
it's been named. **Decision: add a lightweight shared-secret check** (a
static token in gRPC metadata, verified by a unary interceptor on the
monolith side, attached by the gateway's client) — not full mutual TLS,
which is more infrastructure than a two-process, single-tenant system
needs right now, but enough that a misconfigured network or a future
second caller can't silently act as any user just by reaching the port. See
`docs/plans/phase1-fixes-breaker-timeout-grpc-auth.md`.

## Correction (2026-09-04, durable notification delivery)

§4 said flatly: "no outbox table, no relay poll-loop... Publish runs
synchronously in the same request." That's still the right call for every
topic except one, and this correction narrows it rather than reverses it.

**What changed and why.** Building the notification module (pulled forward
from Phase 4, see `docs/plans/03-hardening-pass.md` §E) surfaced that
`push-notification-requested` is qualitatively different from every other
event this system publishes. Every other topic (`user-onboarded`,
`user-profile-updated`, `user-location-updated`, `rating-updated`,
`subscription-*`) feeds an idempotent cache upsert: if the same crash-window
loss §4 accepts as a trade-off happens to one of those, the cache is
briefly stale, it self-heals on the next event that touches the same row,
and a backfill CLI exists for the rare case it doesn't (§C3 in the hardening
pass). `push-notification-requested` has no such recovery path — a lost
"the host accepted your request" is gone forever, with no later event that
would ever re-send it, and it's the one topic that also requires a real
third-party network call (FCM) rather than a same-process DB write. That
combination — user-facing, one-shot, no self-heal, network-call-coupled —
is exactly the profile durability machinery like an outbox exists for.

**Decision: add a Postgres-backed outbox for this one topic only.** Not a
message broker, not a return to real Pub/Sub, not a separate service — a
`meetup.notification_outbox` table (`meetup` already owns every publisher of
this topic), written in the same transaction as the business write it
accompanies, and a generic `internal/platform/outbox` poller package
(reusable by `auth` or `billing` later if either ever needs this same
guarantee for one of its own topics, without re-deriving this design) that
claims due rows via `FOR UPDATE SKIP LOCKED`, attempts delivery, and retries
with backoff up to a dead-letter ceiling. A same-process wake-signal (a
non-blocking channel nudge after commit) keeps common-case latency close to
immediate, with a periodic tick as the safety net — an option a real
separate microservice consumer wouldn't have, since it doesn't share memory
with the writer the way this monolith's two halves of the same process do.

**Explicitly still true, unchanged**: every other topic keeps using
`eventbus.Bus.Publish`/`Subscribe` exactly as built in Phases 1-2, still
synchronous, still no outbox, still the §4 trade-off as originally reasoned.
This is a scoped exception for one topic's specific risk profile, not a
walk-back of §4's general decision.

**Explicitly accepted, not solved**: this delivers at-least-once, not
exactly-once. A crash between a successful FCM send and the outbox row's
`processed_at` update being committed causes a retry and a duplicate
notification. No idempotency key is being added to close this — a rare
duplicate "your request was accepted" push is a minor annoyance, not a
correctness bug, unlike (for example) a duplicate payment. See
`docs/plans/03-hardening-pass.md` §F for the full build spec.

## Correction (2026-09-05, what building the outbox actually required)

The durable-delivery correction above described the design; building it
surfaced three places where the described design and a working one differ.
All three are recorded here rather than silently absorbed, per this
project's own convention.

**The outbox insert cannot be hidden inside the `Sender` implementation.**
`docs/plans/03-hardening-pass.md` §F3 asserted that the outbox write could be
made atomic with the business write "entirely inside the
`notifications.Sender` implementation", with no change to the call sites in
`requests.go`/`service.go`. That is not achievable, and the obstacle is
structural rather than a matter of effort: a `Sender` is invoked AFTER the
business write's repository method has already returned, and that method
opens, commits and closes its own transaction internally. By the time any
`Sender` runs, there is no open transaction left to join — the write is
durably committed, and anything the sender does is a second transaction with
exactly the crash window the outbox exists to close. Atomicity and
"no call-site changes" were mutually exclusive; atomicity is the one that
matters, so the call sites changed. **What was built**: each
notification-triggering repository method takes a callback that runs inside
its own transaction, after the write and before the commit, and receives a
`NotifyTx` — a transaction-scoped surface for reading participants and device
tokens and enqueueing outbox rows. Notification content is still composed
entirely in the service layer, where it belongs; only *when* it is composed
moved.

**`ClaimBatch` writes its claim instead of holding a lock.** The generic
poller's `Store` interface described claiming rows "locked FOR UPDATE SKIP
LOCKED for the duration of the caller's processing". Holding that lock is not
viable for this caller: processing means an FCM round trip, and holding a
Postgres transaction open across a third-party HTTP call lets a degraded FCM
exhaust the connection pool — a dependency failure escalating into a database
failure. So the claim is an `UPDATE` that stamps `next_attempt_at` into the
future, giving each claimed row a visibility timeout. `FOR UPDATE SKIP
LOCKED` remains in the claiming subquery, where it still guarantees that
concurrent claimers take disjoint sets. Crash recovery follows from the same
stamp rather than from lock release: a claimer that dies records no outcome,
and its rows fall due again on their own. **This was not a theoretical
refinement** — the first implementation released the lock without the stamp,
and the concurrency test immediately showed rows being claimed two and three
times by four concurrent claimers, which in production is the same user
receiving the same push two and three times.

**The lifecycle sweeps became claims too.** §C2 asked for `FOR UPDATE SKIP
LOCKED` on the poller's row selection. Adding it to the existing
select-then-act shape would not have been enough, because the gap that
matters is between reading the candidates and recording that they were
handled — the notifications go out inside that gap. Both sweeps are now a
single claiming `UPDATE ... RETURNING` that sets the de-dup guard in the same
statement that selects the rows, with the notifications queued in that same
transaction. A control test that runs the old algorithm under a forced
overlap sends 24 notifications for 12 meetups; the new one sends 12.

## Grounding

This ADR is based on a full inventory of the microservices repo's actual
schemas (`backend/db/migrations/{auth,meetup,billing}/*.up.sql`), proto
contracts (`backend/proto/{auth,meetup,billing}/v1/*.proto`), gateway route
table and middleware (`backend/services/gateway/internal/handlers/handlers.go`,
`internal/middleware/ratelimit.go`), shared packages (`backend/shared/*`),
event publish/consume call sites, and per-service config requirements — not
assumption. See `docs/plans/` for the phased build sequence this ADR feeds
into.
