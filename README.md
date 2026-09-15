# Professional Meetups — Modular Monolith Backend (parallel track)

This is a **separate, parallel project** — not a replacement for the microservices
backend in `../Professional-Meetups`. That repo keeps running as-is; nothing here
touches it. This repo exists to explore a different backend architecture for the
same product: a single deployable ("the monolith") plus a thin API gateway, in
place of five independently-deployed Go services.

## Why

- **One Postgres database, one schema per module** (`auth`, `meetup`, `billing`,
  `notification`, `sos`) instead of five separate databases — while still keeping
  each module's tables isolated (no cross-schema foreign keys), so a module can
  still be pulled back out into its own service later without an untangling
  project.
- **No Redis.** Rate limiting moves into the gateway itself, in-memory, keyed by
  authenticated user ID.
- **No Pub/Sub, no notification-dispatch process.** Cross-module events
  (`meetup-created`, `user-onboarded`, etc.) go through an in-process event bus —
  same publish/subscribe programming model as today, zero extra infrastructure.
  Deploying this system means exactly two things: the gateway, and the monolith.
- **The gateway keeps doing what it does today**: JWT issuance, REST request
  handling, rate limiting, and translating each REST call to gRPC. That gRPC
  hop still crosses a real process boundary — the gateway and the monolith stay
  two separate binaries/deployables, exactly as requested — it just now points
  at one gRPC target instead of three or four. "In-process" only describes what
  happens *inside* the monolith, between its modules (see the event bus below);
  it does not describe gateway-to-monolith calls, which stay gRPC.
- **JWT signing moves into the gateway.** Today the auth service holds the
  private key and signs tokens; gateway and everyone else only verify. Since
  the gateway now sees every request and is the single entry point, it makes
  more sense for it to hold the signing key directly: the monolith's auth
  module authenticates the request (checks credentials/OTP/etc.) and hands back
  "this is user X, trust level Y" over gRPC; the gateway itself mints the
  access/refresh tokens before returning them to the client. The monolith never
  holds the private key.
- **Every module is written so it can be re-extracted into a standalone service
  later** with minimal rewrite — see `docs/decisions/adr-001-modular-monolith-architecture.md`
  for the concrete rules this repo follows to keep that path open.

## Layout

```
Professional-Meetups-Monolith/
├── frontend/       # Copied from the microservices repo, unmodified — same
│                   # REST API surface, so no frontend changes are needed at all.
├── backend/
│   ├── cmd/monolith/       # The single backend binary
│   ├── cmd/gateway/        # The API gateway binary
│   ├── internal/modules/   # auth, meetup, billing, notification, sos —
│   │                       # one Go package per module, each owning its own
│   │                       # Postgres schema and exposing one Go interface
│   ├── internal/eventbus/  # In-process publish/subscribe, zero external infra
│   ├── internal/platform/  # db, jwt, ratelimit — shared infrastructure code
│   └── migrations/         # One migration history, schema-namespaced per module
├── docs/
│   ├── decisions/          # This repo's own ADRs (numbering starts fresh at 001)
│   └── plans/              # Phase-by-phase build plans
```

## Status

Scaffolding only as of 2026-09-04 — see `docs/decisions/adr-001-modular-monolith-architecture.md`
and `docs/plans/` for the phased build sequence. Built module by module, each
phase verified before the next starts (same discipline the microservices backend
itself was built with).

## Building the app for devices

From `frontend/`, use `./build.sh <prod-android|prod-ios|emulator|simulator>`
and nothing else. It passes `--dart-define-from-file=.env` (map provider, LinkedIn
client id) plus the right `GATEWAY_BASE_URL`, and verifies production builds
before reporting success. A hand-typed `flutter build` with only the gateway
URL compiles fine and ships with the map disabled. Details in
`frontend/RUN.md` → "Building for real devices and production".
