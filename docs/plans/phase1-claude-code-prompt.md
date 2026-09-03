# Claude Code prompt — Modular Monolith, Phase 1 (scaffold + gateway + auth module)

You're working in `/Users/as/Documents/Professional Meetups/Professional-Meetups-Monolith` — a **brand-new, separate project**, not the existing microservices repo. The existing repo, `../Professional-Meetups` (sibling directory), is the **source you port from** — read it as much as you need, but never write to it. It keeps running exactly as it is; nothing about this task touches it.

## Read first, in this order

1. `docs/decisions/adr-001-modular-monolith-architecture.md` (in this new repo) — the full architecture decision this build implements. Every numbered decision in it matters; don't skip the "why" sections, they explain trade-offs you need to preserve, not just outcomes.
2. `docs/plans/00-overview.md` (this repo) — the 5-phase sequence. You are building **Phase 1 only**.
3. `docs/plans/01-phase1-scaffold-gateway-auth.md` (this repo) — the detailed step-by-step for exactly what you're building right now.
4. In `../Professional-Meetups/backend`, the actual source you're porting: `services/auth/internal/{service,repository,identity}`, `services/gateway/internal/{handlers,middleware,config}`, `shared/jwt`, `shared/events/payloads.go`, `db/migrations/auth/*.up.sql`, `proto/auth/v1/auth.proto`. Read these in full, not skimmed — this port needs to be behaviorally faithful (same validation rules, same error mapping, same rate limits), and guessing at business logic instead of reading it is exactly the kind of gap this project can't afford this early.

## What "done" looks like

A `cmd/gateway` binary and a `cmd/monolith` binary, two separate processes talking over gRPC, that together handle every route in the inventory's auth/verification/sos/users subset (listed in the phase plan) with the same validation, rate limits, and response shapes as today's gateway+auth — except JWT signing now happens in the gateway, not the monolith (ADR-001 §6 — read this carefully, it changes what the monolith's auth module returns for every session-issuing call).

## Ground rules

- **This is a real Go project.** You have a working toolchain here — actually run `go build ./...`, `go vet ./...`, `go test ./...`, don't just write code and assume it compiles. Set up a local Postgres (docker compose or however this environment already runs Postgres for the sibling repo — check `../Professional-Meetups/backend/docker-compose.yml` for the pattern, e.g. image/version) with the `auth` schema migrated in, and actually exercise at least one full flow end to end (e.g. email OTP signup → profile setup → an authenticated `GET /v1/users/me` call with the real issued token) before reporting this done.
- **Port business logic faithfully.** Validation rules (phone format, OTP expiry/attempt caps, corporate-email free-provider rejection, company-domain matching, the age-confirmation checks, the trusted-contacts cap of 3, the SOS context-message 500-char cap, etc.) all come from reading `services/auth/internal/service` and the validators it calls — copy the actual rules, don't reinvent them from the field names alone.
- **Do not add cross-schema foreign keys** on any column that's a "logical FK, no real constraint" in the original schema (ADR-001 §3 has the reasoning) — even though this is one database now and a real FK is possible, adding one here is exactly the coupling ADR-001 explicitly avoids.
- **Do not build the outbox/relay/circuit-breaker pattern.** Publish events directly via `eventbus.Bus.Publish` in the same call as the business write (ADR-001 §4) — there is no `outbox_events` table in this repo.
- **Do not wire Redis anywhere** — there is no `REDIS_ADDR` config in this repo at all, gateway rate limiting is the in-memory implementation described in the phase plan Step 2.
- **Do not build the `meetup`, `billing`, or `notification` modules** — their routes correctly return 503 this phase (mirroring how the original gateway already handles an unconfigured `BILLING_SERVICE_ADDR`), don't stub fake success responses for them.
- **If you find a genuine ambiguity** the plan doesn't resolve (e.g. a config-loading detail, an exact migration-tool choice) — check how `../Professional-Meetups/backend` itself resolves the equivalent question and mirror it, rather than inventing a new convention for this repo. Consistency with the source project's own conventions matters more than any single stylistic preference.

## When done

Report, in this order: (1) confirmation `go build ./...`/`go vet ./...`/`go test ./...` all ran clean, with real output, not a claim; (2) the exact route table this phase wires (method, path, middleware chain) so it can be checked against the inventory; (3) confirmation of the end-to-end flow you actually exercised and what it proved; (4) anything from the phase plan you deviated from and why; (5) anything you're explicitly leaving as a known gap for Phase 2+ to pick up, named specifically rather than left implicit.
