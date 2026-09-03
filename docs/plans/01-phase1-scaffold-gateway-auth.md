# Phase 1 — scaffold, gateway, auth module

Implements ADR-001 for: repo scaffolding, `internal/eventbus`, the shared
platform packages, the `cmd/gateway` binary, and the `auth` module
(including SOS/trusted contacts, which is part of `auth` here — see ADR-001
§2). Ported from `backend/services/auth` and `backend/services/gateway` in
`../Professional-Meetups`.

## Step 0 — Go module layout

**One Go module for the whole backend** — `backend/go.mod` (module path
`professional-meetups-monolith/backend` — this is a private, unpublished
module, the path just needs to be a stable import prefix, not a resolvable
URL). `cmd/gateway` and `cmd/monolith` are two `main` packages inside this
one module, importing `internal/...` packages directly as normal Go
packages — **no `go.work`, no per-service `go.mod`.** The microservices repo
needed six separate modules because its services were six independently
versioned deployables; here there are only two binaries and they're built
from the same source tree in lockstep, so one module is simpler and correct.
`docker-compose.yml`, both Dockerfiles, and `.github/workflows/backend-ci.yml`
(all already written, this repo) assume this single-module layout — don't
restructure around a different one without updating all three.

## Step 1 — `internal/eventbus`

One file, `backend/internal/eventbus/bus.go`:

```go
type Event struct {
    Topic     string
    Payload   any
    OccurredAt time.Time
}

type Handler func(ctx context.Context, e Event) error

type Bus interface {
    Publish(ctx context.Context, topic string, payload any) error
    Subscribe(topic string, handler Handler)
}
```

In-memory implementation: a `map[string][]Handler}` guarded by a `sync.RWMutex`.
`Publish` looks up all handlers for the topic and invokes them **synchronously,
in the same call**, catching and logging (not propagating) any handler error —
matches ADR-001 §4's "best-effort, never fail the request" posture. Stamp
`OccurredAt = time.Now()` in `Publish` itself so every consumer can still do
the idempotent-upsert-with-timestamp-guard pattern the original consumers use
(a handler compares the incoming event's `OccurredAt` against whatever it has
already stored, skips a stale/superseded delivery). No goroutines, no channels,
no retry loop — there's nothing to retry against (see ADR-001 §4).

Port the topic-name constants and payload struct shapes from
`../Professional-Meetups/backend/shared/events/payloads.go` verbatim (same
field names) — call it `backend/internal/eventbus/events.go`. This phase only
needs `UserOnboardedPayload`, `UserProfileUpdatedPayload`,
`UserLocationUpdatedPayload` published, and nothing subscribing yet (their
consumers are meetup-module, Phase 2) — publish them anyway from this phase's
auth module so Phase 2 has something to subscribe to without touching Phase-1
code again.

## Step 2 — `internal/platform`

- **`db/`** — a thin `pgxpool.Pool` wrapper + a migration runner (reuse
  whatever migration tool the original repo uses — check
  `../Professional-Meetups/backend`'s `Makefile`/`docker-compose.yml` for
  which one, e.g. `golang-migrate` — don't introduce a different one).
- **`jwt/`** — port `../Professional-Meetups/backend/shared/jwt/` (`claims.go`,
  `signer.go`, `verifier.go`) essentially unchanged. This package now lives
  only in the gateway process (ADR-001 §6) — the monolith binary never
  imports it.
- **`ratelimit/`** — a fresh implementation (not a port — the original is
  Redis-backed). Same fixed-window-counter algorithm as
  `../Professional-Meetups/backend/services/gateway/internal/middleware/ratelimit.go`,
  same four key shapes (IP+path, email-keyed, target-keyed, user-keyed — copy
  the exact key-string formats and limits from that file), backed by an
  in-memory `map[string]*bucket` (`bucket{count int; resetAt time.Time}`)
  guarded by a mutex, with a background goroutine sweeping expired entries
  every minute so the map doesn't grow unbounded. Same 429 response shape
  (`Retry-After` header + `{"error":"rate limited"}` body). Same fail-open
  posture is moot here (no external dependency to fail) — every check
  succeeds or correctly 429s, there's no third "couldn't check" state.

## Step 3 — `cmd/gateway`

Port `../Professional-Meetups/backend/services/gateway` structurally, with
these changes from ADR-001:

- One gRPC client target (`MONOLITH_ADDR` config var) instead of
  `AUTH_SERVICE_ADDR`/`MEETUP_SERVICE_ADDR`/`BILLING_SERVICE_ADDR`.
- No `REDIS_ADDR` config at all — `internal/platform/ratelimit` needs no
  connection string.
- Route table for this phase: every `/v1/auth/*`, `/v1/verification/*`,
  `/v1/sos/*`, `/v1/users/me`, `/v1/users/me/location` route from the
  inventory (all of `auth`'s routes) — same paths, same methods, same
  middleware chain (which routes get `requireAuth`, which get email-keyed/
  target-keyed/user-keyed rate limits, at the same limits) as today's
  gateway. `/v1/meetups/*` and `/v1/billing/*` routes return 503 for now
  (same pattern the original gateway already uses when
  `BILLING_SERVICE_ADDR` is unset) — Phase 2/3 fill them in, don't stub
  fake responses.
- Global middleware chain unchanged in shape (`Recover` → request-ID logging
  → `RequestLogging` → the new in-memory IP+path `RateLimit` → `MaxBytes`),
  same 1 MiB body cap, same HTTP server timeouts
  (`ReadHeaderTimeout=10s`/`ReadTimeout=30s`/`WriteTimeout=30s`/
  `IdleTimeout=120s`).
- **JWT signing** (ADR-001 §6): the gateway constructs both the `Signer` and
  the `Verifier` at startup (needs both keys now — `JWT_PRIVATE_KEY_PATH` and
  `JWT_PUBLIC_KEY_PATH`). After a successful auth-module gRPC call that would
  have returned a `SessionResponse` in the original proto, the gateway calls
  `signer.Sign(claims)` itself to produce `access_token`, and issues/stores
  the refresh token the same way `RefreshSession`/login flows do today — the
  monolith's response carries `user_id`, `trust_level`, `is_new_user`,
  profile fields, and (for refresh-token flows) the new refresh-token
  row's raw value, but never a pre-signed access token.

## Step 4 — `internal/modules/auth`

Port `../Professional-Meetups/backend/services/auth`'s `internal/service`,
`internal/repository`, and `internal/identity` (Apple/Google id_token
verification) packages as one Go package, `internal/modules/auth`, exposing a
single `Service` interface with one method per current `AuthService` RPC
(from the inventory: `CompleteFederatedSignup` through `TriggerSOS`, 22
methods) — same request/response Go structs (mechanically translated from the
proto message shapes in the inventory), **minus** the two token fields
removed from the session-returning methods per Step 3.

- **Schema**: `auth.*` — same 10 tables as today's `auth_db` (`users`,
  `refresh_tokens`, `verification_codes`, `user_identities`,
  `known_companies`, `unverified_company_claims`, `trusted_contacts`,
  `sos_events`), same columns/constraints/indexes/triggers, minus
  `outbox_events` (not needed, ADR-001 §4) — migrated via
  `backend/migrations/0001_auth_schema.up.sql` (schema-qualified, `CREATE
  SCHEMA auth; CREATE TABLE auth.users (...)`, etc.).
- **SOS/trusted contacts**: `internal/modules/auth/sos/` sub-package —
  `AddTrustedContact`, `ListTrustedContacts`, `RemoveTrustedContact`,
  `TriggerSOS` — same business logic (Twilio/Resend `SendAlert`, the
  cap-of-3 check, the 500-char `context_message` cap), same
  `sos_events`/`trusted_contacts` tables under the `auth` schema.
- **Publishes** (via `eventbus.Bus`, synchronously, same call site the
  business write happens in — not a separate outbox step):
  `user-onboarded` (on first sign-in/signup), `user-profile-updated` (on
  profile-setup/rating-cache-affecting writes), `user-location-updated` (on
  `UpdateLastKnownLocation`). No subscriptions in this phase (auth consumes
  `rating-updated` from meetup — that's Phase 2, once meetup exists to
  publish it; wire the `Subscribe` call then, not with a dangling handler
  now for an event nothing publishes yet).
- **Config**: same required/optional env vars as today's
  `services/auth/internal/config/config.go` (LinkedIn, Twilio, Resend/Gmail,
  Apple/Google id_token audiences, `WORK_EMAIL_HMAC_KEY_PATH`) minus
  `JWT_PRIVATE_KEY_PATH` (moved to gateway, Step 3) minus `GRPC_PORT`
  (the monolith's own single port covers every module, see Step 5).

## Step 5 — `cmd/monolith`

One binary hosting a single gRPC server (one port, `MONOLITH_PORT`) that
registers the `auth` module's methods this phase (meetup/billing register
theirs in Phases 2/3, same binary, same port — additive, not a rewrite of
this file). Constructs the shared `db.Pool`, the `eventbus.Bus`, and each
module's `Service` in `main()`, wires the module's `Subscribe` calls (none
yet this phase), starts serving.

## Explicitly not in this phase

- `meetup`, `billing`, `notification` modules and their gateway routes
  (Phases 2-4).
- The parity/side-by-side verification pass (Phase 5).

## When done

Report: `go build ./...` / `go vet ./...` / `go test ./...` output for real
(this environment has a working Go toolchain — use it), a list of every
route this phase wires with its exact method+path+middleware (should match
the auth subset of the inventory table exactly), confirmation the JWT
signing-key relocation works end to end (sign in, get a real token back,
call an authenticated route with it), and confirmation the copied
`frontend/` needs zero changes to talk to this gateway for the routes this
phase covers (point `AppConfig`'s base URL at this gateway's port and
exercise the LinkedIn/Apple/Google sign-in + SOS flows for real, or explain
precisely what couldn't be exercised and why).
