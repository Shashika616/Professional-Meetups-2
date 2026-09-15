Read `docs/plans/19-schedule-conflict-race-fix.md` in full first, and
`docs/decisions/adr-005-one-meetup-at-a-time.md` for the feature this fixes.
Also read `docs/gap-tracker.md`'s #17 entry — the trust-level race fix — for
the lock-then-callback pattern this fix should mirror rather than reinvent.

## Fix 1 (High) — close the schedule-conflict check-then-act race

Move `checkScheduleConflict` from running *before* the write transaction
(as it does today in both `CreateMeetup`, `service.go:278`, and
`RequestToJoin`, `requests.go:32`) to running *inside* the same transaction
the subsequent `Create` opens, immediately after acquiring
`pg_advisory_xact_lock(hashtext(<user id as text>))` as that transaction's
first statement. Reuse the lock-then-callback shape `GetUserByIDForUpdate`
already established for gap #17 — don't invent a new pattern. Both
`CreateMeetup` and `RequestToJoin` need this; make sure the advisory lock
key is derived from the correct user (the host for `CreateMeetup`, the
requester for `RequestToJoin`).

Add a genuine concurrency test: two goroutines racing to create (or
request) overlapping-window meetups for the same user, against a real test
database connection pool — assert exactly one succeeds and the other gets
`ScheduleConflictError`. Run it against the pre-fix code first and confirm
it actually fails (flaky/racy without the lock), then confirm it passes
after the fix — report both results, not just the final pass.

## Fix 2 (Medium, comments only) — cross-reference the duplicated "live meetup" definition

Add one-line cross-referencing comments at `FindScheduleConflict`
(`repository/queries/meetups.sql`), `ListActiveMeetups`'s `isLive` closure
(`service.go`), and `ListOpenMeetups`'s browsable filter (`meetups.sql`),
each pointing at the other two by name. Do not refactor the SQL or extract
a shared constant — comments only, per the plan doc's explicit reasoning.

## Verification

`go build ./... && go test ./...`. Report the concurrency test's before/
after results explicitly, plus confirm no existing schedule-conflict test
(`schedule_conflict_integration_test.go`) regressed.
