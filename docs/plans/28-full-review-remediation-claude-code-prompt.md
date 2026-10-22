# Claude Code prompt: Plan 28, full review remediation

Read first: `CLAUDE.md`, `TESTING-NOTES.md`, `docs/plans/28-full-review-remediation.md`, `docs/security-review-2026-10-21.md`, `docs/security-review-2026-10-01.md`, `docs/gap-tracker.md` (#51-#96), `docs/decisions/adr-009-*.md`, `docs/plans/26-otp-race-double-accept-cancel-guard-completion-report.md`.

## Task

Implement Plan 28 in three phases (A, B, C), in order. The plan's tables give, per tracker number, the exact change. Work on the current working tree on top of the existing uncommitted changes.

## Hard rules

1. Do not commit, push, deploy, run `gcloud`, or touch any production or Supabase database. Write migrations (next number is 0019) and test them against the local test database only.
2. Do not remove or weaken test users, seeded test emails, `TEST_OTP_BYPASS_EMAILS` reserved-TLD enforcement, or the scoped bypass behaviour in `TESTING-NOTES.md`. The only change near them is refusing `ALLOW_TEST_OTP_BYPASS=true` when `K_SERVICE` is set. If a change would affect a test fixture, stop and say so in the report.
3. A provider-verified email still counts as the personal email toward Level 2.
4. Every fix needs a test that fails before the change and passes after. Concurrency fixes need a `-race` test with real concurrent goroutines against Postgres. Show the failing-before output once in the report.
5. No invented UI. Only these UI changes are allowed: SOS failure states (Retry, Call emergency services), a "Waiting for confirmation" state and confirm entry for trusted contacts, and a privacy-policy text addition. Use existing `AppPalette`, `FlatCard`, `PrimaryButton`.
6. Do not create secrets, keystores, or cloud IAM. Write instructions in the runbook for the pieces only Shashika can do (Android keystore, Workload Identity Federation setup) and make the code read them from environment or `key.properties`.
7. Stop and ask (write the question in the report and continue with the default) only for the decisions D1 to D6 in the plan; use the bracketed defaults unless `docs/plans/28-decisions.md` exists and says otherwise.
8. Keep generated code in sync (`sqlc generate`, proto generation) and run the repo's format and lint steps. Do not hand-edit generated files.

## Procedure per phase

1. Re-read the phase table. List the files you will touch.
2. Implement tracker item by item, smallest diff that closes the finding. Prefer a single conditional SQL statement over read-then-write.
3. After each item run the relevant package tests; after the phase run `go vet ./...`, `go test -race ./...`, `flutter analyze`, `flutter test`, `dart format --set-exit-if-changed`.
4. Phase B and C: for every query changed, record `EXPLAIN (ANALYZE, BUFFERS)` before and after on a seeded local database (add `backend/scripts/seed-load.sh` seeding 100k users and 100k meetups) and put the numbers in the report.
5. Write `docs/plans/28A-completion-report.md` (then 28B, 28C): per tracker item what changed, tests added, deviations, anything left open and why. Update `docs/gap-tracker.md` statuses and `docs/security-review-2026-10-21.md` section 1. Do not mark an item DONE without a passing test.
6. Do not begin the next phase until the report exists.

## Phase specifics to get right

- **A, #79 migration 0019:** build the new partial unique index before dropping the old constraint; down migration restores the old constraint only if no duplicate rows exist, otherwise fails with a clear message. Cover reject-after-rereq, final-seat accept with a previously rejected pending user, withdraw of a second acceptance, and a user already accepted trying to create a second pending row.
- **A, #82:** add the normalised target column in a migration, backfill in the same migration, add the unique index after the backfill. Existing codes are short-lived; it is fine to delete expired rows first.
- **A, #78:** location becomes optional end to end (proto, gateway JSON, service, SMS/email text says "location unavailable"). Test: no location, timeout, offline, 5xx, session expired.
- **A, #83:** the family revoke on reuse must also publish the existing session-revoked signal if one exists.
- **B, #81:** the Postgres limiter must fail open for non-sensitive routes and fail closed for OTP, login, phone, SOS and share when the database is unavailable; document that choice. Hash keys before storing; never store raw emails or phones in the counters table.
- **B, #80:** grandfather existing contacts as confirmed in the migration. Alerts and shares go only to `confirmed` contacts. SOS with zero confirmed contacts must still show "Call emergency services".
- **B, #88:** outbox consumers must be idempotent by event id; add a scheduled reconcile job for each denormalised cache with a `cache_lag_seconds` metric.
- **C:** splitting files must not change behaviour; run the full suite before and after each split and keep git-diff size reviewable by splitting one aggregate per step. `main.go` under 250 lines, no Go or Dart file over 600 lines except generated code; list any exception with a reason.
- **C, CI:** workflows must pass on the current tree; if govulncheck or gosec report existing issues, fix them or record each with an explicit, dated suppression and a tracker row.

## Final report

After Phase C, write `docs/plans/28-final-report.md` with: a table of the six scores before and after and which exit criterion from the plan each one met (or did not), the tracker items closed and still open, p95 numbers from the load script, and the list of things only Shashika can do (keystore, WIF, Cloud Run annotation deploy, applying migrations in order, rotating anything). Update the vault note `03 - Architecture/Security Review 2026-10-21.md` status section only if the vault is available to you; otherwise list what to copy.
