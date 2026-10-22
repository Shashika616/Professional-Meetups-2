# Plan 26 — Close V-1 (OTP attempt race), V-2 (double accept), V-10 (cancel guard)

Source: `docs/security-review-2026-10-01.md` (V-1, V-2, V-10), tracker #51, #52, #59.
Scope: three small, local fixes. No schema migration is needed. Not in scope: V-3/V-4 (limiter), V-5 (release signing), V-6 phone half.

Decision recorded 2026-10-08: a provider-verified email counts as the personal email toward Level 2 (ADR-009, tracker #72). Task 4 only pins that with a test.

## Task 1 — V-1: make the OTP attempt cap race-proof

Problem: `verifyAndConsumeCode` (`auth/verification.go`) and `verifyAndConsumeTargetKeyedCode` (`auth/service.go`) read the row, check `Attempts >= 5`, compare, and only then increment. Parallel guesses all see `attempts = 0`.

Fix:
1. New sqlc queries in `auth/repository/queries/verification_codes.sql`: an atomic claim-an-attempt that does `UPDATE ... SET attempts = attempts + 1 WHERE <key> AND attempts < 5 AND expires_at > now() RETURNING *` (one for user-keyed, one for target-keyed). Zero rows means locked out or expired.
2. Service flow becomes: claim an attempt first (zero rows -> same error as today's lockout/expiry), then compare the code against the returned row, then on match consume with `DELETE ... WHERE <key> AND code_hash = $x RETURNING` so one code cannot be consumed twice (zero rows -> treated as invalid).
3. Keep error messages and codes identical to today. Keep the test-bypass checks where they are (they skip before this path).
4. Resend upsert still resets `attempts = 0` (documented in tracker #13); do not change it.
5. Apply to every purpose including `account_claim`. Check `isEmailOTPPurpose` call sites.
6. Run `sqlc generate`; never hand-edit `sqlcgen`.

Tests: integration test firing 50 parallel wrong guesses at one code; assert at most 5 were evaluated and the rest are rejected. Test two parallel correct submissions: exactly one succeeds. Existing OTP tests still pass.

Test-email constraint (Shashika, 2026-10-08): the `TEST_OTP_BYPASS_EMAILS` allowlist and seeded `@meetups.test` users stay. The bypass check runs before the new attempt-claim code, so add a test that a bypass email still verifies with `123456` and a non-bypass address does not.

## Task 2 — V-2: double accept

Problem: the accept transaction (`meetup/repository/meetup_requests_postgres.go`) reads the request as pending before locking the meetup; `AcceptMeetupRequest` has no status predicate, so a second accept re-accepts and double-counts the seat.

Fix:
1. In `queries/meetup_requests.sql` add `AND meetup.meetup_requests.status = 'pending'` to `AcceptMeetupRequest`. Zero rows (`pgx.ErrNoRows`) maps to a conflict error (use the existing `apperror` conflict/precondition type; check what the handler maps it to).
2. Inside the transaction, lock the meetup row first, then re-read the request `FOR UPDATE`, then update.
3. Derive full-ness from `CountAcceptedRequests` after the update instead of `acceptedCount + 1`.
4. Check the reject and withdraw queries for the same missing status predicate and fix them in the same way if present (they must not resurrect or overwrite a resolved request).

Tests: two concurrent accepts of the same request on a capacity-2 meetup: one succeeds, one conflicts, meetup stays `open`, no other request auto-rejected. Accept after reject/withdraw returns conflict.

## Task 3 — V-10: cancel guard

Problem: `CancelMeetup` is `WHERE id = $1 AND host_user_id = $3`, so a host can cancel a completed or already-cancelled meetup.

Fix:
1. Add `AND status IN ('open','full')` to `CancelMeetup` in `queries/meetups.sql`. Decide with the existing lifecycle code whether to also require `window_end > now()`; if `CloseMeetup` already owns the past-window case, only the status guard is needed, and say so in the report.
2. Zero rows: distinguish not-found from wrong-state (the service already loads the meetup, so check status there too and return the conflict error). The repo layer must map `ErrNoRows` to conflict, not not-found, once ownership has been verified.
3. Notifications must not fire on a rejected cancel (they are queued inside the same transaction, so the early return suffices; confirm).

Tests: cancel completed -> conflict, status unchanged, no notifications; cancel cancelled -> conflict; cancel open/full still works; existing `TestTrigger_CancelMeetup_*` pass.

## Task 4 — pin the Level 2 decision

Add a unit test in `auth/trustlevel_test.go`: a user with LinkedIn sub, phone, legal name and a provider-sourced `PersonalEmail` is Level 2 with no OTP step. No behaviour change.

## Task 5 — docs

Update `docs/gap-tracker.md` (#51, #52, #59 -> DONE with date), the "Status update" in `docs/security-review-2026-10-01.md`, and write `docs/plans/26-...-completion-report.md`.

## Verification (all required)

`cd backend && go build ./... && go vet ./... && go test ./...` including the integration tests (needs the local Postgres used by existing integration tests). Run the new concurrency tests with `-race -count=20`.

## Deploy notes

No migrations. Deploy with the normal Cloud Run flow. 0017 and 0018 are still pending from ADR-009 and are independent of this work; if they ship together, apply the migrations first.
