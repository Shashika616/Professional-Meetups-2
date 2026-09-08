# Completion report — async meetups-completed recompute

Scope: `docs/plans/async-meetups-completed-recompute-claude-code-prompt.md`,
working from `docs/plans/06-async-meetups-completed-recompute.md`. Nothing
outside the recompute/outbox path was touched, and
`UpsertUserMeetupsCompletedCache`'s WHERE clause — the prior round's guard fix
— is untouched (verified below).

`internal/platform/outbox` is used **unmodified**: `Row.Payload` is opaque to
it, so the package needed nothing for a second caller. Only a table, a
`Store`, a process function and a poller instance are new.

---

## 1. New table

`backend/migrations/0006_meetups_completed_outbox.{up,down}.sql`.

`meetup.meetups_completed_outbox` with `meetup_ids UUID[]` in place of
`notification_outbox`'s FCM columns, and the same three partial indexes
(`_claimable` on `next_attempt_at`, `_retention` on `processed_at`,
`_dead_lettered` on `dead_lettered_at`).

**One row per completion batch, not per meetup.** The recompute query already
de-duplicates participants across ids via its `UNION`, so per-meetup rows
would multiply claim/poll overhead *and* recount a shared participant once per
meetup instead of once. Asserted by
`TestAutoCloseSweep_SchedulesOneRowForTheWholeBatchAndWakes_Integration`.

The down migration notes that reversing this loses only not-yet-processed
*intents*, which is recoverable — the counts derive from `meetup.meetups` /
`meetup.meetup_requests`, which are untouched. That is materially different
from 0003's down, and worth saying rather than leaving to be discovered.

## 2. `Close()` and `claimSweep()`

`backend/internal/modules/meetup/repository/meetups_postgres.go`.

- `Close()` — `enqueueMeetupsCompletedRecompute(ctx, q, []Meetup{closed})` at
  **:647**, on the closing transaction, in the exact place the inline
  recompute used to sit. Commit at **:651**. `r.wakeMeetupsCompleted()` at
  **:659**.
- `claimSweep()` — the same insert at **:859**, guarded by `completes`.
  Commit at **:864**. Wake at **:872**, likewise guarded.

`enqueueMeetupsCompletedRecompute` is defined at **:728**; the query is
`EnqueueMeetupsCompleted` in
`repository/queries/meetups_completed_outbox.sql`.

`recomputeMeetupsCompleted` (**:685**) and
`RecomputeMeetupsCompletedForParticipants` are **not deleted** — they are now
called from the poller's handler. `recomputeMeetupsCompleted` took `[]Meetup`
and now takes `[]string`, because its caller is a poller holding a decoded
payload rather than a repository method holding rows it just wrote. It also
now returns `outbox.ErrPermanent` for an unparseable id, so a structurally
broken row is dead-lettered on the first attempt instead of burning ten
retries.

`publishMeetupsCompleted` is **gone** — publishing left the closing path
entirely.

## 3. `Store` implementation

`backend/internal/modules/meetup/repository/meetups_completed_outbox_postgres.go`,
mirroring `outbox_postgres.go` method for method, with
`var _ outbox.Store = (*postgresMeetupsCompletedOutboxRepository)(nil)` as
compile-time proof.

The claim query (`ClaimMeetupsCompletedOutboxBatch`) is the proven strategy
copied, not a new one: `UPDATE … WHERE id IN (SELECT … FOR UPDATE SKIP LOCKED)`
stamping `next_attempt_at` into the future as a visibility timeout, `attempts`
incremented at claim time, `ORDER BY next_attempt_at` matching the partial
index.

Two shared decisions, both deliberate and commented at the source:

- `ClaimVisibilityTimeout` is **shared** with the notification outbox rather
  than given its own constant. This processing is database-only and finishes
  far inside 60s, so a second number would be one more thing to reason about
  for no benefit.
- The stronger motivation for the UPDATE-based claim (never hold a Postgres
  transaction open across a third-party HTTP call) does **not** apply here.
  The pattern is kept anyway — the concurrency guarantees are what matter, and
  one claiming strategy in the codebase beats micro-optimising the second.

`Row.Payload` is `MeetupsCompletedPayload{MeetupIDs []string}` marshaled as
JSON, mirroring how `NotificationPayload` is populated rather than inventing a
convention.

## 4. Poller and handler

`backend/internal/modules/meetup/completedrecompute.go` —
`CompletedRecompute.Process`, shaped like `notification.Delivery.Process` so
`cmd/monolith` wires two pollers the same way.

It decodes the row, calls the unchanged
`RecomputeForMeetups`, and publishes one
`eventbus.MeetupsCompletedUpdatedPayload` per result — **same topic, same
payload, same consumer** (`auth.ApplyMeetupsCompletedUpdate`), all unchanged.
Only *when* changed.

Error handling, all of it delegated to the poller's existing machinery:

| Case | Result |
|---|---|
| Undecodable payload | wrapped in `outbox.ErrPermanent` → dead-lettered immediately |
| Unparseable meetup id | same, from `recomputeMeetupsCompleted` |
| Empty id list | success — nothing to do, and retrying will not change that |
| Recompute query error | returned → the poller's backoff/retry applies |
| Publish error | logged, not returned — the bus is in-process, so this means a *consumer* failed, and re-running the whole recompute (re-publishing for every participant who succeeded) is not the right answer. The consumer's write is idempotent. |

Wired in `backend/cmd/monolith/main.go`: store at **:192**, poller at **:212-216** (both before the meetup
repository, which needs the poller's `Wake`), started at **:411**.

**No metrics observer, deliberately** (commented at the construction site).
`outboxObserver` writes to counters named `notification_outbox_*`, and
`OutboxPending` is a `Set()` gauge — reusing it would both mislabel the data
and have two pollers race on one gauge, each overwriting the other's count.
Giving this poller its own metric names is a small separate change; it is
flagged rather than smuggled in by reusing the wrong ones. **This is the one
thing this round leaves undone.**

## 5. Wake — checked, not assumed

The prompt called this out specifically because a poller built but never woken
was a self-found bug in the original notification outbox work. Verified three
ways:

**By grep** (`meetups_postgres.go`):
```
647:	if err := enqueueMeetupsCompletedRecompute(ctx, q, []Meetup{closed}); err != nil {
651:	if err := tx.Commit(ctx); err != nil {
659:	r.wakeMeetupsCompleted()
...
859:		if err := enqueueMeetupsCompletedRecompute(ctx, q, claimed); err != nil {
864:	if err := tx.Commit(ctx); err != nil {
872:		r.wakeMeetupsCompleted()
```
Both wakes are **after** their commit, not before.

**By construction**: `NewMeetupRepository` gained a `wakeMeetupsCompleted
func()` parameter (**:68**). It is a function rather than the poller itself
both to keep the repository package unaware of `outbox.Poller` and to break
what would otherwise be a construction cycle — the poller needs a `Store`, and
the repository needs the poller's `Wake`.

**By test**: the harness passes a counting wake, and
`TestCloseMeetup_SchedulesRecomputeWithoutRunningIt_Integration` and
`TestAutoCloseSweep_SchedulesOneRowForTheWholeBatchAndWakes_Integration` each
assert exactly one wake. `TestStartingSoonSweep_SchedulesNoRecompute_Integration`
asserts **zero** — the starting-soon sweep shares `claimSweep` but completes
nothing, so waking it would be a guaranteed-empty drain every minute.

## 6. Retention

Checked before writing anything: `notification.Retention` was **already**
parameterized by `RetentionStore`, not by table name. So the new table needed
a second instance and no new logic.

The one thing that was notification-specific was the log text, now a `label`
field (`internal/modules/notification/retention.go`) — a job logging
"notification outbox retention" while deleting from a different table would be
actively misleading during an incident. `NewRetention` keeps its exact
signature and behaviour by delegating to the new `NewRetentionFor`, so no
existing call site or test changed.

```
cmd/monolith/main.go:407:	go notification.NewRetention(notificationOutbox, logger).Run(ctx)
cmd/monolith/main.go:408:	go notification.NewRetentionFor("meetups-completed outbox", meetupsCompletedOutbox, logger).Run(ctx)
```

Same `ProcessedRetention` (7d) / `DeadLetterRetention` (30d) windows, same
batched-delete shape. Covered by
`TestMeetupsCompletedStore_RetentionDeletesTerminalRows_Integration`.

---

## Tests

**New** — `backend/internal/modules/meetup/meetups_completed_outbox_integration_test.go`
(12 tests):

- `TestMeetupsCompletedClaimBatch_ConcurrentClaimersNeverOverlap_Integration` —
  4 concurrent claimers, 60 rows, no row claimed twice, nothing left due.
  Mirrors the notification outbox's. It matters *less* here (a duplicate
  recompute is a no-op, not a duplicate push) but an overlapping claim would
  mean N claimers each running the expensive recompute over the same meetups,
  which is exactly the load this plan exists to remove.
- `TestMeetupsCompletedStore_MarkTransitions_Integration` — processed /
  dead-lettered leave the pending set, failed does not, `attempts` is
  incremented at claim time, and a failed row respects its backoff.
- `TestMeetupsCompletedStore_RetentionDeletesTerminalRows_Integration`.
- Four handler tests: publishes for every participant (de-duplicated across
  two meetups — one event at count 2, not two events at 1); undecodable
  payload is permanent; unparseable id is permanent and publishes nothing;
  empty payload succeeds.
- **`TestCloseMeetup_SchedulesRecomputeWithoutRunningIt_Integration`** — the
  one that proves the handoff rather than each half alone. Closes a real
  meetup, asserts the outbox row exists *and names that meetup*, asserts the
  event has **not** been published, asserts the wake fired, then runs one
  poller pass and asserts the event now exists with the right count and the
  row is drained.
- `TestAutoCloseSweep_SchedulesOneRowForTheWholeBatchAndWakes_Integration`.
- `TestStartingSoonSweep_SchedulesNoRecompute_Integration`.

**Updated** — every test that asserted synchronous publish-on-close. Grepped
for `TopicMeetupsCompletedUpdated` across `*_test.go`; there were exactly two,
both in `integration_test.go`, both updated deliberately rather than left to
contradict the new design:

| Test | Change |
|---|---|
| `TestCloseMeetup_PublishesMeetupsCompletedForEveryParticipant` | Now asserts the close publishes **zero** events synchronously, then drains the outbox. Every original assertion (host and accepted requester counted, rejected requester not, exactly two users) is unchanged — which is the point. |
| `TestMeetupsCompleted_CountsAccumulateAndAreAbsolute` | Re-run against the new path. Same `[1, 2, 3]` assertion. Drains after **each** close, not once at the end: a single drain would process all three rows against the final database state and publish `3, 3, 3`, passing a weaker assertion while proving nothing about accumulation — and one drain per close is what production does, since each close wakes the poller. |

**Harness** — `integration_test.go` gained the new table to its `TRUNCATE`, a
counting wake, and three helpers (`drainCompletedOutbox`,
`pendingCompletedRows`, `completedOutboxMeetupIDs`).

---

## Confirmations

**1. `Close()`/`claimSweep()` no longer call the recompute directly.** Full
grep of the repository package (excluding generated `sqlcgen`):

```
$ grep -n "recomputeMeetupsCompleted\|RecomputeMeetupsCompletedForParticipants\|publishMeetupsCompleted" \
    internal/modules/meetup/repository/*.go | grep -v sqlcgen
meetups_postgres.go:663:// recomputeMeetupsCompleted builds the meetups-completed events for a batch
meetups_postgres.go:669:// commits. RecomputeMeetupsCompletedForParticipants re-derives each
meetups_postgres.go:702:	rows, err := q.RecomputeMeetupsCompletedForParticipants(ctx, ids)
meetups_completed_outbox_postgres.go:73:	return recomputeMeetupsCompleted(ctx, r.q, meetupIDs)
```

Two comment lines, the query call *inside* `recomputeMeetupsCompleted` itself,
and one real call site — `RecomputeForMeetups`, which only the poller's
handler invokes. Neither `Close()` nor `claimSweep()` appears.
`publishMeetupsCompleted` returns no matches at all.

**2. Wake is called at both commit points.** Quoted in §5 above, with line
numbers showing both come after their `tx.Commit`, plus three tests asserting
the counts (1, 1, and 0 for the non-completing sweep).

**3. Retention covers the new table.** `cmd/monolith/main.go:408`, quoted in
§6, using the same `Retention` type the notification outbox uses.

**4. The prior round's guard fix is untouched.**
`UpsertUserMeetupsCompletedCache` still reads
`AND sqlc.arg(meetups_completed)::int > meetups_completed` — guarded on the
count, not the timestamp. Not edited in this round.

**5. Gates.**

```
go build ./...            ok
go vet ./...              ok
golangci-lint run ./...   0 issues.
go test ./... -race       exit 0 (21 packages ok, 0 failures, no data races)
```

## Deployment note

Migration `0006` is applied by the golang-migrate container at
`docker compose up`, so the stack needs a restart. No backfill and no
data migration — the table starts empty and fills from the next completion.
