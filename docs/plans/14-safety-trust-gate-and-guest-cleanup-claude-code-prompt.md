Two pieces of work, do Part A fully before starting Part B — Part B's
simplified design (only two eligibility conditions) depends on Part A
already being in place. Full design and reasoning for both is in
`docs/plans/14-safety-trust-gate-and-guest-cleanup.md` and
`docs/decisions/adr-003-safety-features-require-level-2-trust.md` — read
both before making changes.

## Part A — Level 2 trust gate on AddTrustedContact / TriggerSOS

Today `AddTrustedContact` and `TriggerSOS` only require being logged in —
no trust-level check at all, so even a never-verified guest account can
use them. Add trust level 2 (the same floor required to join a meetup) as
a server-enforced gate.

1. Add `int32 caller_trust_level` to `AddTrustedContactRequest` and
   `TriggerSOSRequest` in `backend/proto/auth/v1/auth.proto`. Regenerate
   via this repo's `buf generate` setup — don't hand-edit the `.pb.go`
   files.
2. Add `CallerTrustLevel int` to both request structs in
   `backend/internal/modules/auth/sos/sos.go`.
3. Add a `requireSafetyFeatureTrustLevel` gate function in the `auth`
   package (new file or alongside `trustlevel.go`) mirroring
   `backend/internal/modules/meetup/trustgate.go`'s `checkTrustLevel`
   exactly — same error shape (`apperror.ErrForbidden`, wrapped with a
   message naming the action and both trust levels). Constant
   `safetyFeatureTrustFloor = 2`.
4. Call that gate from `service.go`'s `AddTrustedContact` and
   `TriggerSOS` methods (lines ~210, ~222), before delegating to
   `s.sos.X(ctx, req)`. Exact code shape is in the plan doc.
5. Thread `CallerTrustLevel` through the same chain gap #25's fix already
   established for `ListRatableParticipants` (see
   `docs/plans/13-round3-bug-fixes.md` Fix 4 for the precedent shape):
   `monolithclient` interface + implementation → gateway handler in
   `handlers/sos.go` sourcing `int32(middleware.TrustLevelFromContext(ctx))`
   → `grpcapi`'s auth handlers → the service request. Update any fake
   `MonolithClient`/test doubles to match the new signatures.
6. On the frontend: add optional `title`/`description` params to
   `VerificationChecklistPage` (defaulting to the exact current copy, so
   every existing call site is unaffected), then in `safety_page.dart`
   gate the "add trusted contact" entry point and `_onSosTapped` behind a
   client-side `trustLevel < 2` check — same `ToastType.locked` +
   push-`VerificationChecklistPage` pattern `meetup_card.dart`'s
   `_handleLockedTap` already uses, with Safety-specific copy (exact
   wording suggestions are in the plan doc, feel free to refine). Server
   side is what's actually enforced; this is UX.
7. Add backend tests (sub-2 rejected, Level 2+ accepted) and a frontend
   widget test on the locked-toast-and-redirect behavior.
8. Run `go build ./...` and treat its output as the authoritative list of
   every call site needing the new parameter — don't assume the plan
   doc's file list is complete.

## Part B — Guest-account cleanup

Extend the existing `backend/internal/modules/auth/sweeper.go`'s
`RefreshTokenSweeper` — don't build a separate poller. After its existing
`SweepExpiredRefreshTokens` step, also delete `auth.users` rows where
`is_guest = true` AND there is no row for that user in `auth.refresh_tokens`
at all AND the account has been in that state for at least
`RefreshTokenRetention` (reuse that existing constant, don't add a second
retention window). Exact SQL shape (anti-join, not a stored "signed out"
flag) is in the plan doc's Part B — this table is small (guest signup is
rate-limited to 5/IP/day) so a periodic scan is fine, don't build an
incremental/event-driven version.

New repository method `DeleteAbandonedGuests`, batched the same way
`DeleteExpired` already is. Call it from `RefreshTokenSweeper.Tick` right
after the existing sweep, logged the same way.

Before writing this, confirm directly (query or test, not assumption) that
a guest account genuinely has no rows anywhere else that would be orphaned
by deletion — `refresh_tokens`/`verification_codes`/`user_identities`/
`unverified_company_claims` all cascade via existing FKs, and Part A
closes the `trusted_contacts`/`sos_events` gap, but check for anything
else added since this plan was written before relying on that.

Add the four tests described in the plan doc's B4 (deleted when eligible,
survives with a live token, survives if never a guest, survives within the
retention grace window).

## When done

Run `go build ./...`, `go test ./...` (backend), `flutter analyze
--fatal-infos`, `flutter test` (frontend). Report the actual output, and
list every file changed with a one-line description — not a prose summary
of "added the gate and the cleanup job."
