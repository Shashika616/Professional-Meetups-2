# Build plan overview — modular monolith backend

Five phases, each handed to Claude Code as its own prompt and verified before
the next starts — same discipline the original microservices backend was
built with, applied here because this is a comparable amount of business
logic to port correctly. See `docs/decisions/adr-001-modular-monolith-
architecture.md` for the architecture every phase below implements.

| Phase | Scope | Depends on |
|---|---|---|
| **1** | Repo scaffold, `internal/eventbus`, `internal/platform/{db,jwt,ratelimit}`, the gateway binary (JWT signing + in-memory rate limiting + gRPC client + REST routes wired for auth-module routes only), the `auth` module (identity, verification, sessions, profile, SOS/trusted contacts) end to end. | Nothing — first phase. |
| **2** | `meetup` module (scheduling, lifecycle/auto-close, requests, safety gate, ratings, geo-visibility, device tokens, the three read-model caches fed via the event bus) + its gateway routes. | Phase 1 (needs the event bus, `auth`'s `user-onboarded`/`user-profile-updated`/`rating-updated`/`user-location-updated` events to exist and be published). |
| **3** | `billing` module (subscription state, Apple/Google purchase verification, webhook handling) + its gateway routes. | Phase 1 (JWT/gateway plumbing). Independent of Phase 2's module internals, but its `subscription-activated`/`subscription-deactivated` events need a Phase-2-built `meetup` module subscriber to be meaningful end to end — buildable in parallel with Phase 2, verified together. |
| **4** | `notification` module (FCM/logging `Sender`, the `push-notification-requested` event handler) wired to `meetup`'s `meetup-created` nearby-notify fan-out and to SOS's contact-alert path. | Phases 1-3 (needs `auth` for SOS/trusted-contacts data, `meetup` for the nearby-notify query and device tokens). |
| **5** | Final hardening + parity pass: run both backends side by side against the same frontend build (pointed at each gateway in turn) and diff behavior for every route in the inventory; confirm rate-limit numbers, error shapes, and response fields match; confirm the copied `frontend/` needs zero code changes; write a migration/cutover note. | Phases 1-4. |

## What "verified" means at the end of each phase

Not just "compiles." For each phase: `go build ./...`, `go vet ./...`,
`go test ./...` actually run (this environment has no Go toolchain — Claude
Code must run these itself, not just claim to); a fresh Postgres instance
with only that phase's schemas migrated in; and for phases that add gateway
routes, the exact request/response shape checked against the inventory this
plan is grounded on (`docs/decisions/adr-001-modular-monolith-architecture.md`'s
"Grounding" section) — not just "returns 200."

## Quality bar — applies to every phase, not just Phase 1

Non-negotiable, per Shashika's explicit instruction. A phase is not "done"
until all of these hold, and its completion report must address each one
explicitly (not just claim "done" and move on):

- **Completeness.** Every RPC, route, and business rule for that phase's
  module — from `docs/decisions/adr-001-modular-monolith-architecture.md`'s
  "Grounding" inventory — is ported. The completion report must include an
  explicit checklist against the relevant inventory rows, so a silent gap
  can't hide behind a general "looks complete."
- **No client-side-only validation, anywhere.** The copied `frontend/`'s own
  validators exist for instant UI feedback only, never as the source of
  truth — every module re-validates every rule server-side as if the
  frontend didn't exist. Read the source's actual validation logic; don't
  infer a rule from a field name.
- **Security.** Walk `docs/security-review-framework.md`'s full six-property
  checklist against the module just built, in the completion report, not as
  an unstructured bug hunt. That doc also names two specific,
  currently-unfixed vulnerabilities in the source code being ported — the
  Apple/Google `id_token` replay gap (missing `nonce` check, Phase 1 scope)
  and the Safety Gate's missing per-participant authorization check (Phase 2
  scope) — both must be **fixed during the port**, not carried forward
  silently just because the source has them. Every SQL query parameterized,
  no exceptions; every authorization decision sourced from the verified JWT
  context, never a client-supplied field; secrets never logged.
- **Code quality, algorithms, data structures.** Idiomatic Go; the
  `apperror` sentinel-error pattern used consistently rather than ad hoc
  error strings; no unbounded queries (pagination capped, same limits as the
  source); no accidental O(n²) where an indexed lookup or a single query
  would do; no N+1 query patterns introduced where the source used a single
  join/batch call.
- **Real, run tests — not claimed ones.** Unit tests for pure logic
  (validators, pure functions) plus integration tests against a real,
  ephemeral Postgres for anything touching the database — both actually
  executed (`go test ./...`, real output in the report), not written and
  assumed passing. Cover adversarial/negative cases explicitly, not just the
  happy path: wrong-owner/IDOR attempts, expired or tampered tokens,
  oversized input, boundary conditions on every rate limit.
- **Design review.** Before declaring a phase done, explicitly check it
  against ADR-001's own rules — no cross-schema foreign keys, no
  reintroduced outbox/relay/circuit-breaker machinery, no module reaching
  into another module's repository/SQL directly, event-bus `Publish` calls
  in the same transaction as the business write. A phase that quietly
  drifts from ADR-001 "because it was easier" is a finding to report and
  fix, not a silent judgment call.

## Sequencing note

Phase 1 is the only one queued right now. Phases 2-5 get their own prompt
once Phase 1's completion report has been independently reviewed — same
verify-before-handoff pattern used throughout the original backend's build
(see `../Professional-Meetups/docs/00-project/action-tracker.md` for that
project's own history of this pattern, for reference only — this repo keeps
its own tracker once there's enough history to warrant one).

