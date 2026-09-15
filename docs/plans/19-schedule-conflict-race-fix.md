# Plan 19 — Close the schedule-conflict race, cross-reference the duplicated "live" definition

Fresh review of the just-added one-meetup-at-a-time feature (ADR-005),
specifically asked to check for duplicate logic, inconsistencies, logical
errors, memory leaks, and network/battery drain. Two independent
from-scratch reviews (backend, frontend); the one real bug below was
personally re-verified against source before being recorded.

## Fix 1 (High) — `checkScheduleConflict` is check-then-act with no lock; two ordinary concurrent requests defeat the whole feature

**Verified directly.** `schedule_conflict.go`'s `checkScheduleConflict` runs
a plain, unlocked `FindScheduleConflict` SELECT. Both call sites —
`CreateMeetup` (`service.go:278`) and `RequestToJoin` (`requests.go:32`) —
call it, get a clean answer, and only *afterward* open their own separate
`Create` transaction (`meetups_postgres.go:114`,
`meetup_requests_postgres.go:75`). Nothing — no advisory lock, no row lock,
no transaction spanning the check and the write — stops two requests from
the same person arriving close together from both passing the check before
either commits.

This is not the narrow "two creates in the same millisecond" case the
ADR's Consequences section frames as a theoretical, accepted gap — it's
reproducible by an ordinary flaky-network retry, a double-tap that slips
past client-side debouncing, or two concurrent requests, and it defeats the
specific reason pending requests were made to count in the first place: if
two `RequestToJoin` calls for overlapping meetups race past the check, both
pending requests get created, and two hosts accepting independently later
reproduces the exact double-booking this feature exists to prevent.
`RespondToRequest` never re-checks (by design, per the ADR — enforcement
only happens "at the two moments the person acts"), so nothing downstream
catches it either.

**Fix: a Postgres advisory transaction lock, scoped per user, held across
the check and the write.** This needs no new constraint and no migration
against the existing overlapping production rows the ADR already ruled out
an exclusion constraint for — an advisory lock is a serialization
primitive, not a data constraint, so it's safe to add regardless of what's
already in the table.

Shape: `pg_advisory_xact_lock(hashtext(user_id))` — hashing the UUID into
the lock key `pg_advisory_xact_lock` wants — acquired as the **first**
statement inside the same transaction that later performs the `Create`
(meetup or request), immediately followed by re-running the conflict check
*inside* that same locked transaction before proceeding. Two concurrent
calls for the same user now serialize on the advisory lock: the first to
acquire it checks-then-writes without interference; the second blocks until
the first transaction commits or rolls back, then runs its own check
against the now-committed state and correctly sees the conflict.

Concretely:
1. `CreateMeetup` and `RequestToJoin` currently call `checkScheduleConflict`
   *before* opening the write transaction. Move the check inside the
   transaction that `Create` already opens, immediately after acquiring the
   advisory lock as that transaction's first statement.
2. Add a repository method (or extend the existing `Create` methods) to
   accept a "pre-flight check" callback run after the lock is held but
   before the insert — mirroring the shape `GetUserByIDForUpdate`'s
   lock-then-callback pattern already established for the trust-level race
   fix (`docs/gap-tracker.md` #17) uses. Reuse that pattern rather than
   inventing a new one.
3. `hashtext(user_id)` takes a string and returns an `int4` — confirm the
   user ID (UUID) is passed as its text form, and note in a comment that a
   hash collision between two different users' locks is a false-positive
   serialization (mild, harmless perf cost), never a false negative
   (missed conflict) — advisory lock keys share a 32-bit space per Postgres
   session, a fine tradeoff here since the lock is only ever held briefly.
4. Add a test that actually exercises concurrency — two goroutines each
   attempting to create/request overlapping-window meetups for the same
   user at the same time — and asserts exactly one succeeds. A sequential
   test (call, then call again) does NOT prove this fix; it must actually
   race two goroutines against a real test database connection pool.

## Fix 2 (Medium, documentation only) — cross-reference the duplicated "live meetup" definition

**Verified.** "Live" (`status IN ('open','full') AND window_end > now()`)
is written out independently in at least three places:
`FindScheduleConflict` (`repository/queries/meetups.sql:535-536`),
`ListActiveMeetups`'s `isLive` closure (`service.go:518-521`), and (a
related but distinct definition — `open` only, no `full`) `ListOpenMeetups`'s
browsable filter (`meetups.sql:113,185`). Two more raw occurrences of the
`status IN ('open','full')` fragment exist elsewhere in `meetups.sql` for
the lifecycle sweep and host-close-check queries. None of these are
currently wrong — they all agree today — but nothing ties them together,
unlike the ST_DWithin-exemption logic elsewhere in this same file, which
has an explicit comment warning future editors the two paginated queries
"would eventually drift" if not kept in sync.

**Fix, deliberately small**: add a one-line comment at each of the
`FindScheduleConflict`, `isLive`, and `ListOpenMeetups` definitions,
cross-referencing the others by name/location, so a future change to what
"live" or "browsable" means has a pointer to every place that needs the
same edit. Do not refactor the SQL into a shared fragment or introduce a
Go constant used to build query strings in this pass — sqlc's generated-code
model doesn't make that cheap, and the risk of introducing a real bug while
"cleaning up" four working, already-tested queries outweighs the benefit of
a documentation-only gap. Revisit as a real refactor only if a fourth
call site or an actual drift incident makes the case for it.

## Not fixed, tracked only (Low, frontend review)

- `meetup_card.dart:56` / `meetup_detail_page.dart:258` use the plain
  `meetup.intent.label` ("MEAL") rather than the new `meetup.intentLabel`
  (which would show the meal-sitting name) in the trust-locked toast — but
  both sites only render when the meetup is locked for the viewer, and
  ADR-028 already redacts `windowStart` in that case, so `intentLabel`
  falls back to the same plain label regardless. No behavior difference
  today; flagged so a future change to that redaction rule doesn't silently
  desync these two sites from the rest of the app.
- `ScheduleConflictError.message()`'s plain-text fallback doesn't
  distinguish a pending vs. accepted conflicting request (both read "you
  already have a meetup at that time") — the structured `conflict` field
  the real app UI reads does distinguish correctly via `myRequestStatus`.
  Only affects a hypothetical client that ignores the structured detail.

## Verification

`go build ./... && go test ./...`, with particular attention to the new
concurrency test actually failing against the pre-fix code (run it once
before the fix lands, confirm it fails, then confirm it passes after) —
the same discipline gap #17's fix already used ("a control run confirmed it
fails on the old code").

## Outcome (2026-09-15)

Both fixes landed.

- **Fix 1**: `repository.ScheduleGuard` / `ScheduleTx` added; both `Create`
  methods take a guard, run `LockUserSchedule`
  (`pg_advisory_xact_lock(hashtext(user_id))`) as the transaction's first
  statement, then the guard, then the insert. The service's unlocked
  pre-check was removed; `meetup.scheduleGuard` is the only check.
  `TestScheduleConflict_ConcurrentCallsSerialize` races two goroutines on
  a barrier, six rounds each for hosting and requesting. Control run on the
  unlocked code: **every round** let both calls through (`2 of 2 concurrent
  calls succeeded`). With the lock: all rounds pass, exactly one wins.
- **Fix 2**: cross-reference comments at `FindScheduleConflict`,
  `ListOpenMeetupsFirstPage`/`AfterCursor` (browsable) and the `isLive`
  closure in `ListActiveMeetups`. No SQL refactor.
- ADR-005 updated: the "advisory against a true race" consequence no longer
  holds and was replaced with the lock's own caveats.
