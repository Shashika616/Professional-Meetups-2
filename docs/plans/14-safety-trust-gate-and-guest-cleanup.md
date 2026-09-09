# Plan 14 — Safety features Level 2 gate (ADR-003) + guest-account cleanup

Two independent pieces of work, in one plan because the second is only
safe in its simplified form because of the first (see ADR-003's
Consequences). Do Part A before Part B if doing both in one pass, so the
cleanup job's "only two conditions" assumption is actually true by the
time it ships.

## Part A — Trust-level 2 gate on AddTrustedContact / TriggerSOS

### A1. Proto

`backend/proto/auth/v1/auth.proto`:

```proto
message AddTrustedContactRequest {
  string user_id = 1; // set by the gateway from the verified JWT
  string name = 2;
  string phone_number = 3;
  string email = 4;
  // ADR-003 — set by the gateway from the verified JWT's trust_level
  // claim, never a client-supplied value. AddTrustedContact/TriggerSOS
  // require Level 2, the same floor as joining a meetup.
  int32 caller_trust_level = 5;
}
```

Same addition (`int32 caller_trust_level = 5;`, or the next free field
number in that message) on `TriggerSOSRequest`. Field name matches the
convention already used elsewhere (`viewer_trust_level` on the meetup
messages) in spirit — `caller_trust_level` here because these two RPCs
frame it as "the caller," not "the viewer," matching the existing Go-side
naming in `sos.go`'s request structs once this field is added there too;
use whichever reads more naturally, but be consistent between the two
messages.

Regenerate stubs via this repo's existing `buf generate` setup
(`backend/buf.gen.yaml`) — do not hand-edit the generated `.pb.go` files.

### A2. Go request types

`backend/internal/modules/auth/sos/sos.go` — add `CallerTrustLevel int` to
both `AddTrustedContactRequest` (line ~54) and `TriggerSOSRequest` (line
~71). `service.go` already aliases both
(`AddTrustedContactRequest = sos.AddTrustedContactRequest`,
`TriggerSOSRequest = sos.TriggerSOSRequest`, lines 61/64) so no separate
type needs updating there.

### A3. The gate itself

New file or addition to an existing one in `backend/internal/modules/auth`
(e.g. alongside `trustlevel.go`) — mirror
`backend/internal/modules/meetup/trustgate.go`'s `checkTrustLevel` shape
exactly:

```go
// safetyFeatureTrustFloor is the trust level required to add a trusted
// contact or trigger SOS (ADR-003) — the same floor required to join a
// meetup. Trusted contacts and SOS exist to protect someone meeting a
// stranger; joining already requires this level, so gating the safety
// tools at a lower bar than the thing they protect during would be
// backwards.
const safetyFeatureTrustFloor = 2

// requireSafetyFeatureTrustLevel is the server-side gate, non-negotiable
// regardless of what the client's own UI already checks — callerTrustLevel
// comes from the JWT via the gateway, never a client-supplied value.
func requireSafetyFeatureTrustLevel(action string, callerTrustLevel int) error {
	if callerTrustLevel < safetyFeatureTrustFloor {
		return fmt.Errorf(
			"auth: %s requires trust level %d, caller has %d: %w",
			action, safetyFeatureTrustFloor, callerTrustLevel, apperror.ErrForbidden,
		)
	}
	return nil
}
```

Call it from `service.go`'s two delegation methods, before calling into
`s.sos`:

```go
func (s *service) AddTrustedContact(ctx context.Context, req AddTrustedContactRequest) (TrustedContact, error) {
	if err := requireSafetyFeatureTrustLevel("adding a trusted contact", req.CallerTrustLevel); err != nil {
		return TrustedContact{}, err
	}
	return s.sos.AddTrustedContact(ctx, req)
}

func (s *service) TriggerSOS(ctx context.Context, req TriggerSOSRequest) (TriggerSOSResult, error) {
	if err := requireSafetyFeatureTrustLevel("triggering SOS", req.CallerTrustLevel); err != nil {
		return TriggerSOSResult{}, err
	}
	return s.sos.TriggerSOS(ctx, req)
}
```

Don't push this check into the `sos` subpackage itself — it stays a plain
CRUD/alerting layer, same reasoning as its own doc comment about the
validator being "injected rather than duplicated."

### A4. Threading the trust level through

Same chain gap #25 (`docs/plans/13-round3-bug-fixes.md` Fix 4) already
established for `ListRatableParticipants` — follow that precedent exactly:

1. `backend/internal/gateway/monolithclient/monolithclient.go` —
   `AddTrustedContact`/`TriggerSOS` interface methods gain a
   `callerTrustLevel int32` parameter.
2. `backend/internal/gateway/monolithclient/*.go` (wherever the
   `grpcClient` implementations for these two live — likely `sos.go` or
   similar) — accept the new parameter, set it on the proto request.
3. `backend/internal/gateway/handlers/sos.go` — `addTrustedContact` and
   the SOS-trigger handler source
   `int32(middleware.TrustLevelFromContext(ctx))` from the verified JWT
   and pass it through, the same one-line addition
   `handlers/meetups.go`'s `listMeetupParticipants` already makes.
4. `backend/internal/grpcapi` (wherever the auth server's
   `AddTrustedContact`/`TriggerSOS` handlers live) — read
   `req.GetCallerTrustLevel()` and set it on the service-layer request.
5. Update `handlers/sos_test.go` / any fake `MonolithClient` implementation
   to match the new interface signatures.
6. Run `go build ./...` and fix every other call site it flags — the
   compiler's error list is the source of truth for completeness, the
   list above is a starting point, not a guarantee of every touched file.

### A5. Frontend

`frontend/lib/features/verification/verification_checklist_page.dart` —
add optional `title`/`description` constructor parameters, defaulting to
the current copy exactly (`'UNLOCK JOINING MEETUPS'` /
`'Complete these to reach Level 2 trust and unlock joining meetups.'`), so
every existing call site (`meetup_card.dart`, wherever else it's pushed
today) compiles unchanged with identical behavior. This is a pure
reuse-with-parameterization, not a new page — the checklist rows, the
LinkedIn banner, the COMPLETE button all stay exactly as they are.

`frontend/lib/features/safety/safety_page.dart`:

- Read the current profile's trust level (same provider pattern
  `meetup_card.dart`'s `_handleLockedTap` and `HostingUnlockPage` already
  use — `ref.watch(authSessionProvider).value?.profile`).
- Gate the "Add trusted contact" entry point (wherever
  `ManageTrustedContactsPage` is currently pushed from — check
  `safety_page.dart` and `manage_trusted_contacts_page.dart` for the exact
  entry point(s), there may be more than one) and the SOS button's tap
  handler (`_onSosTapped`): if `trustLevel < 2`, show the same
  `ToastType.locked` toast pattern with safety-specific wording (e.g.
  `'Trusted contacts and SOS require Level 2 trust. Verify your phone,
  personal email, and details to unlock them.'`), then push
  `VerificationChecklistPage` with Safety-specific `title`/`description`
  (e.g. `'UNLOCK SAFETY FEATURES'` /
  `'Complete these to reach Level 2 trust and unlock trusted contacts and SOS.'`)
  instead of proceeding.
- This client-side check is UX only, same as everywhere else in this
  codebase — the server-side gate from Part A is what's actually
  enforced. Still worth adding a fallback: if the server rejects with the
  new `apperror.ErrForbidden` for this specific reason despite the
  client-side check passing (a stale cached profile), catch it and route
  to the same unlock page rather than showing a raw error toast. Check how
  `RequestToJoin`'s equivalent stale-profile case is handled, if it is, and
  mirror that; if no such fallback exists anywhere yet, the client-side
  check alone is consistent with current practice and this can be a
  follow-up, not a blocker for this plan.

### A6. Tests

- Backend: a service-level test (mirror `trustlevel_test.go`'s or
  `trustgate`'s style) asserting `AddTrustedContact`/`TriggerSOS` reject a
  sub-2 caller with `apperror.ErrForbidden` and accept a Level 2+ caller.
- Frontend: a widget test on `SafetyPage` asserting the locked-toast +
  navigation happens for a sub-2 profile and the normal flow proceeds for
  Level 2+, mirroring however `meetup_card_test.dart`'s locked-tap test
  (if one exists) is structured.

## Part B — Guest-account cleanup job

Now safe with exactly two conditions, because of Part A: a guest can never
have written to `trusted_contacts`/`sos_events`, so no third exclusion
check is needed.

### B1. Eligibility

A guest account (`is_guest = true`) is eligible for deletion once it has
**zero refresh-token rows that are still valid** — not revoked, not
expired — AND has been in that state for at least a grace period (mirror
`RefreshTokenRetention`'s reasoning: a recent expiry should stay
inspectable for a moment, not vanish instantly). Recommend reusing the
same `RefreshTokenRetention` constant (7 days) rather than inventing a
second retention window — one number to reason about, not two.

This is a join, not a flag: `auth.users` has no "last signed out" column
and none should be added — the refresh_tokens table is already the source
of truth for "can this account still authenticate," and adding a second,
derivable fact risks drifting out of sync with it.

### B2. Where this hooks in

Extend `backend/internal/modules/auth/sweeper.go`'s existing
`RefreshTokenSweeper`, rather than building an entirely separate poller —
it already runs hourly, already knows which users just lost their last
live token, and the existing doc comment explicitly frames this file's
job as "disk hygiene, not correctness," which is exactly what guest-row
cleanup is too. Concretely:

- After `SweepExpiredRefreshTokens` deletes a batch of dead refresh-token
  rows, it now has (or can cheaply get) the set of `user_id`s just
  affected. For each one, check: is this user still `is_guest = true`,
  and do they now have zero valid refresh tokens at all (not just zero
  *deleted-this-batch* ones — a user can have multiple tokens; only
  delete once ALL of them are gone). If both hold, the account is a
  cleanup candidate.
- Don't delete immediately on the same tick — batch candidates and delete
  them in the same sweep only if they've already been candidates for at
  least `RefreshTokenRetention` past their last token's death, mirroring
  the existing grace-window reasoning. The simplest correct
  implementation: a repository method that finds `is_guest = true` users
  with no row in `refresh_tokens` at all (an anti-join) whose
  `updated_at` (or `created_at`, whichever this schema uses as "last
  touched") is older than `RefreshTokenRetention` — this sidesteps
  needing to track "which users were just affected" as separate state,
  at the cost of a periodic full scan instead of an incremental one.
  Given this table's expected size (guest signups are rate-limited to
  5/IP/day — see `accountCreationLimit`), a scan is cheap enough here;
  don't over-engineer an incremental version for a table this small.
- New repository method, e.g. `DeleteAbandonedGuests(ctx, retention
  time.Duration, batchSize int) (deleted int, err error)` on
  `UserRepository`, same batched-loop shape as
  `RefreshTokenRepository.DeleteExpired` — one `DELETE ... WHERE is_guest
  = true AND NOT EXISTS (SELECT 1 FROM auth.refresh_tokens WHERE
  user_id = auth.users.id) AND updated_at < $1 LIMIT $2` (or equivalent),
  looped the same way `SweepExpiredRefreshTokens` loops
  `DeleteExpired` until a batch comes back short.
- Call the new method from `RefreshTokenSweeper.Tick`, right after
  `SweepExpiredRefreshTokens`, logged the same way (`"guest account
  cleanup", "deleted", n`). Don't create a second `Run`/`Ticker` — one
  sweeper doing two related jobs on the same schedule is simpler than two
  sweepers that could drift out of sync.

### B3. Cascade safety

Since the earlier ADR-003 gate is in place, a deleted guest's row cascades
cleanly: `refresh_tokens`, `verification_codes`, `user_identities`,
`unverified_company_claims` all have `ON DELETE CASCADE` to `auth.users`
(migration 0001) and a never-verified guest has no rows in any of the
other tables that matter (`trusted_contacts`/`sos_events` — now
unreachable for a guest per Part A; `meetup.*` — Level 0 can't join or
host, per `trustgate.go`'s existing floors). Confirm this with a query or
test before shipping, don't just assume it from the schema read — a
migration added after this plan was written could change that.

### B4. Tests

- A unit test seeding a guest with an expired/revoked-only token set past
  retention, asserting the row is deleted.
- A test seeding a guest with a still-valid token, asserting the row
  survives.
- A test seeding a non-guest (upgraded) account with no live tokens,
  asserting the row survives regardless — `is_guest = false` must be a
  hard exclusion, this is the one assertion that most needs to never
  regress.
- A test seeding a guest inside the retention window (token just died,
  not yet past the grace period), asserting the row survives until the
  next eligible tick.

## Verification

`go build ./...`, `go test ./...` for the backend; `flutter analyze
--fatal-infos`, `flutter test` for the frontend. Report actual output for
both.
