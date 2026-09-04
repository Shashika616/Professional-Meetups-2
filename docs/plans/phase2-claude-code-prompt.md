# Claude Code prompt — Modular Monolith, Phase 2 (meetup module)

You're working in `/Users/as/Documents/Professional Meetups/Professional-Meetups-Monolith`.
Phase 1 (gateway + auth module) is built and reviewed — this phase adds the
meetup module additively. Don't restructure what Phase 1 built; `cmd/monolith/main.go`
has comments marking exactly where this phase's wiring goes.

## Read first, in this order

1. `docs/decisions/adr-001-modular-monolith-architecture.md`, **including its
   "Corrections" section** — added after Phase 1 review, changes what §6/§7
   actually mean in practice.
2. `docs/plans/00-overview.md`'s Quality Bar section — applies in full.
3. `docs/plans/02-phase2-meetup-module.md` — the detailed step-by-step for
   this phase.
4. `docs/security-review-framework.md` — this phase is explicitly
   responsible for fixing the Safety Gate authorization gap it names; walk
   all six properties before reporting done.
5. `backend/internal/eventbus/events.go` — the topic constants and payload
   types this phase publishes/subscribes to already exist, written during
   Phase 1 specifically so this phase wouldn't need to invent them. Use them
   as-is.
6. In `../Professional-Meetups/backend`, the source you're porting:
   `services/meetup/internal/{service,repository}`, `db/migrations/meetup/*.up.sql`,
   `proto/meetup/v1/meetup.proto`, `shared/geo`, `shared/geocoding`. Read in
   full — same faithfulness requirement as Phase 1, with two deliberate
   exceptions already specified in the phase plan (the Safety Gate
   per-participant schema, and the `ListOpenMeetups` host-bypass-radius
   fix) — port everything else exactly, including validation rules and
   error mapping.

## Ground rules (same as Phase 1, repeated because they still apply)

- Real Go project — actually run `go build ./...` / `go vet ./...` /
  `go test -race ./...`, real output, not a claim.
- No client-side-only validation — every rule enforced server-side
  regardless of what the frontend already checks.
- Every SQL query parameterized. Every authorization decision sourced from
  the verified caller context (now doubly true: the gateway's JWT-verified
  user_id, passed to the monolith over the shared-secret-authenticated gRPC
  call from Phase 1's fix prompt) — never a client-supplied field.
- No cross-schema foreign keys (ADR-001 §3) — `meetup.*` tables reference
  `auth.users.id`-shaped columns as plain UUIDs, same as the source's
  cross-database columns today.
- No outbox/relay/circuit-breaker reintroduced for event delivery — publish
  directly via `eventbus.Bus.Publish`, in the same transaction/call as the
  business write. (The SOS-alert breaker from Phase 1's fix prompt is a
  different thing — a real external-vendor breaker — and has no analog
  here; don't add one for the event bus.)
- No Redis, no Pub/Sub emulator.
- Write and actually run real tests, including adversarial cases: a
  mismatched-owner accept/reject/withdraw/cancel/close attempt, a
  non-participant Safety Gate access attempt, a below-trust-level
  `CreateMeetup`/`RequestToJoin` attempt, the host-bypass-radius case and
  its stranger-still-excluded control case.
- If you find a genuine ambiguity the plan doesn't resolve, check how
  `../Professional-Meetups/backend` resolves the equivalent question and
  mirror it, same as Phase 1.

## The two deliberate deviations from a straight port — don't miss either

1. **`meetup.safety_state` is `PRIMARY KEY (meetup_id, user_id)` from the
   start**, not the source's `PRIMARY KEY (meetup_id)`. All four
   Safety-Gate-mutating/reading methods need an `IsParticipant` guard before
   touching it — port the guard pattern the source's ratings code already
   uses (`ListRatableParticipants`'s IDOR fix), don't invent a new shape.
2. **`ListOpenMeetups`'s WHERE clause includes `m.host_user_id = $2 OR` in
   front of the `ST_DWithin` check** — the phase plan has the exact SQL.
   Reuses the existing viewer-ID parameter, no new one needed.

## When done

Report per `docs/plans/00-overview.md`'s Quality Bar plus the phase plan's
own "When done" section: completeness checklist against the meetup subset of
ADR-001's inventory; the six-property security walk, with explicit test
evidence for both the Safety Gate fix and the host-bypass-radius fix; real
build/vet/test output including the adversarial cases; the
`rating-updated` consumer you had to add on the auth side (name the file);
confirmation the Phase-1 shared-secret gRPC interceptor covers this phase's
new RPCs without modification; and anything you're leaving as an explicit
gap for Phase 3 (billing) or Phase 4 (notification) to pick up.
