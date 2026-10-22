# Claude Code prompt — fix V-1, V-2, V-10 from the security review

You're working in `/Users/as/Documents/Professional Meetups/Professional-Meetups-Monolith`.
The 2026-10-08 security review found three verified bugs. Root causes are already diagnosed; don't re-investigate, but do read the code before editing it.

## Read first

1. `docs/plans/26-otp-race-double-accept-cancel-guard.md` in full. It is the plan; follow it task by task.
2. `docs/security-review-2026-10-01.md` sections V-1, V-2, V-10.
3. `TESTING-NOTES.md`. The test OTP bypasses (`ALLOW_TEST_OTP_BYPASS`, `TEST_OTP_BYPASS_PHONES`, `TEST_OTP_BYPASS_EMAILS`) and the seeded `@meetups.test` users are intentional fixtures. Do not remove or change them. Shashika uses the test emails (`TEST_OTP_BYPASS_EMAILS`, `.test` TLD) and the seeded users to test the app, so they must keep working exactly as today after your changes. Add a test proving a bypass email still verifies with `123456` through the reworked V-1 path (and that a non-bypass address does not).

## The three fixes

- **V-1:** OTP attempts are incremented only after the compare, so parallel guesses beat the 5-attempt cap. Claim an attempt atomically first (`UPDATE ... WHERE attempts < 5 ... RETURNING`), then compare, then consume with `DELETE ... RETURNING`. Both `verifyAndConsumeCode` (verification.go) and `verifyAndConsumeTargetKeyedCode` (service.go), all purposes including `account_claim`.
- **V-2:** the accept transaction checks `pending` before locking the meetup and `AcceptMeetupRequest` has no status predicate. Lock the meetup first, re-read the request `FOR UPDATE`, add `AND status = 'pending'`, map zero rows to a conflict, and derive full-ness from `CountAcceptedRequests`. Check reject/withdraw queries for the same gap.
- **V-10:** `CancelMeetup` has no status guard. Add `status IN ('open','full')`, map a wrong-state result to a conflict (not "not found"), and make sure no notifications are queued on a rejected cancel.

Also add one unit test pinning that a provider-verified email counts as the personal email for Level 2 (Shashika decided this on 2026-10-08; no behaviour change).

## Rules

- Edit SQL in `queries/*.sql` and run `sqlc generate`. Never hand-edit `sqlcgen`.
- No migrations. Keep existing error messages and codes unless the plan says otherwise.
- Keep the change minimal. Don't touch the rate limiter, Android signing, or phone canonicalisation; those are separate work.
- Never print secret values from `.env` or key files.
- Do not commit or push. Leave the changes in the working tree; the tree already holds uncommitted ADR-009 work, so don't revert or reformat it.

## Tests

Write the concurrency tests listed in the plan (parallel wrong guesses, parallel correct submissions, concurrent accepts, cancel on completed/cancelled meetups). They must fail on the old code and pass on the new. Run:

`cd backend && go build ./... && go vet ./... && go test ./... && go test -race -count=20 ./internal/modules/auth/... ./internal/modules/meetup/...`

## Finish

Update `docs/gap-tracker.md` (#51, #52, #59 done, with date) and the status section of `docs/security-review-2026-10-01.md`, and write `docs/plans/26-otp-race-double-accept-cancel-guard-completion-report.md` covering what changed, test output, anything you deviated on, and anything you found but did not fix.
