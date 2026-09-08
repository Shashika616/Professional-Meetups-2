# Claude Code prompt — move the meetups-completed recompute off the closing transaction

You're working in `/Users/as/Documents/Professional Meetups/Professional-Meetups-Monolith`.
The Home/Events redesign and its hardening carryover are done. This is a
single, well-scoped follow-up from that review: a scalability finding in the
meetups-completed cache, found during independent review (not self-reported).
A related correctness bug from the same review (the cache write's guard
comparing timestamp instead of count) is already fixed directly — don't
re-touch `UpsertUserMeetupsCompletedCache`'s WHERE clause, it's correct as-is.

## Read first

`docs/plans/06-async-meetups-completed-recompute.md` in full — this prompt
summarizes it, that document has the real detail and reasoning. Also read
whichever files currently implement the notification outbox's `Store`
(`internal/platform/outbox.Store`) and its wiring in `cmd/monolith/main.go`
— this work is a close mirror of that, reusing the same generic
`internal/platform/outbox` package unmodified.

## What to do

1. **New table** `meetup.meetups_completed_outbox` — same shape as
   `meetup.notification_outbox` (migration `0003`) minus the FCM-specific
   columns, storing just `meetup_ids UUID[]`. Same partial-index pattern for
   claiming and retention (see plan doc §1 for the exact DDL).
2. **`Close()` and `claimSweep()`** (`internal/modules/meetup/repository/
   meetups_postgres.go`): replace the inline `recomputeMeetupsCompleted(...)`
   call with a plain insert into the new outbox table (the completed meetup
   IDs), same transaction, same place in the code. Remove the post-commit
   `r.publishMeetupsCompleted(ctx, completed)` call from both — publishing
   moves to the new poller entirely. Do **not** delete
   `recomputeMeetupsCompleted`/`RecomputeMeetupsCompletedForParticipants` —
   they get called from the new poller's handler instead.
3. **New `Store` implementation** for the new table — copy the existing
   notification outbox's `Store` implementation's shape exactly (same
   `FOR UPDATE SKIP LOCKED` claim query, same partial-index usage), don't
   design a new claiming strategy.
4. **New `outbox.Poller` instance**, wired in `cmd/monolith/main.go`
   alongside the existing notification poller. Its handler: unmarshal meetup
   IDs from the claimed row, call the existing
   `RecomputeMeetupsCompletedForParticipants`, publish one
   `eventbus.MeetupsCompletedUpdatedPayload` per resulting row exactly as
   today (same topic, same consumer, unchanged) — only *when* this runs
   changes. Return success/failure for the poller's existing
   retry/backoff/dead-letter handling to apply — no new retry logic.
5. **Call this poller's `Wake()`** right after both `Close()`'s and
   `claimSweep()`'s transactions commit. This exact thing — a poller built
   but never woken — was a self-found bug in the original notification
   outbox work, so verify explicitly that both call sites actually wake it,
   don't assume.
6. **Retention job**: extend it to also cover the new table (same
   processed/dead-lettered retention windows). Check whether it's already
   parameterized by table before writing a second copy.

## Tests

See plan doc's Tests section. Priority: the `Store` implementation's
concurrent-claim test (mirrors the notification outbox's), and the
integration test that closes a real meetup, confirms the outbox row exists
and the profile cache is *not yet* updated, runs one poller tick, and
confirms it now is — that's the test that actually proves the handoff works,
not just that each half works alone. Update every existing test that
currently asserts synchronous publish-on-close; don't leave one contradicting
the new design next to a passing new test (same discipline as prior rounds).

## Bar for "done"

File:line citations, not assertions. Specifically confirm by grep that
`Close()`/`claimSweep()` no longer call the recompute functions directly;
confirm both commit points actually call the new poller's `Wake()`; confirm
retention covers the new table; confirm `go build`/`go vet`/`golangci-lint`/
`go test ./... -race` all pass. Don't touch the cache-write guard fix from
the prior round, and don't touch anything outside this recompute/outbox path.
