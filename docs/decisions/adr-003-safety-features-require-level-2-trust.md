# ADR-003 — Safety Features (Trusted Contacts, SOS) Require Trust Level 2

## Status

Accepted (2026-09-09).

## Context

`AddTrustedContact` and `TriggerSOS` (ADR-026 in the vault, "Minimal Real
SOS: Trusted Contacts + a Real Emergency Alert") were built before the
guest-login/trust-level-0-3 redesign (ADR-002 here, canonical decision
ADR-033 in the vault) existed, and ADR-026 never discusses trust level at
all — it's entirely about scope (a minimal real version vs. the fuller
Safety Features Catalog vision) and architecture (which module owns what).
Nobody made a decision either way about who should be allowed to use these
two features; the question simply didn't exist yet when they were built.

Checked directly against current code: both routes
(`POST /v1/sos/contacts`, the trigger-SOS route) require only
`h.requireAuth` — any authenticated caller, including a guest account
(Level 0, is_guest = true, zero verification of any kind) can add a trusted
contact and trigger a real SOS alert today.

This surfaced while designing a background job to clean up abandoned guest
accounts (guest signs up, never verifies, eventually signs out — see the
accompanying plan doc). `auth.trusted_contacts` and `auth.sos_events` were
both deliberately built with no real foreign key to `auth.users` (migration
0001's header: "adding one would be precisely the coupling that makes
re-extracting a module a data-migration project"). That's a reasonable
choice on its own, but it means deleting an abandoned guest account that
happened to add a contact or trigger SOS would silently leave orphaned rows
behind — pointing at a user that no longer exists, with nothing to clean
them up either.

## Decision

`AddTrustedContact` and `TriggerSOS` now require trust level 2, enforced
server-side, non-negotiable — the same floor already required to join a
meetup (`requiredTrustLevelToJoin` in the meetup module) and the same floor
`participantIdentityFloor` already uses for "can this viewer see who's on a
meetup." Consistent, not arbitrary: trusted contacts and SOS exist to
protect someone meeting a stranger, and joining a meetup already requires
Level 2.

The gate lives in `auth`'s `service.go`, in the two delegation methods
(`AddTrustedContact`, `TriggerSOS`) that already exist as thin wrappers over
the `sos` subpackage — checked before delegating, mirroring the meetup
module's existing `checkTrustLevel` pattern (`trustgate.go`) exactly:
caller's trust level comes from the JWT via the gateway, never a
client-supplied value, and a caller below the floor gets
`apperror.ErrForbidden`, not a silent no-op.

The frontend reuses `VerificationChecklistPage` (parameterized with
Safety-specific copy, since its Level 2 scope is already exactly right) —
the guest still sees the Safety Center page, the checklist, and the SOS
button, so they learn the feature exists and why it's worth reaching Level
2 for. Tapping either action while below the floor shows the same
"locked" toast + push-to-checklist pattern already used for a locked
meetup card and the hosting-unlock flow, rather than a dead button or a
raw error.

## Consequences

- Closes the orphaned-data risk described above outright: a guest who can
  never write to `trusted_contacts`/`sos_events` can never leave orphaned
  rows there, so the guest-account cleanup job (separate plan) needs only
  two conditions (`is_guest = true`, no live refresh token), not a third
  check for prior safety-feature activity.
- No schema change and no data migration for existing rows — this is a
  forward-only gate on two write RPCs, not a retroactive check. Any
  trusted contacts or SOS events already created by a guest account before
  this ships are left exactly as they are.
- `AddTrustedContactRequest`/`TriggerSOSRequest` (both proto and Go) each
  gain a caller-trust-level field, the same shape as `ListRatableParticipantsRequest`
  gained `viewer_trust_level` for gap #25 — full chain: proto → generated
  stubs → `monolithclient` → gateway handler (sourcing
  `middleware.TrustLevelFromContext(ctx)`) → `grpcapi` → service.
- A guest who reaches Level 2 gets full access immediately — nothing new
  is required beyond what Level 2 already means; this ADR doesn't invent a
  separate "safety trust level."

## Related

ADR-002 (this repo, guest login/trust-level 0-3) · ADR-026 in the vault
(Minimal Real SOS — the feature this gates, built before trust level 0-3
existed) · `docs/plans/14-safety-trust-gate-and-guest-cleanup.md` (this
decision's implementation, plus the guest-cleanup job it simplifies) ·
`backend/internal/modules/meetup/trustgate.go` (the pattern this mirrors)
