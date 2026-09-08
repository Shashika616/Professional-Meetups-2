# Plan — move the meetups-completed recompute off the closing transaction's critical path

Follow-up to the review that shipped alongside the Home/Events redesign
(`docs/plans/05-home-events-redesign.md`'s completion report, "meetups
completed" section). That review already fixed a real correctness bug (the
cache write was guarded on wall-clock time instead of the count itself —
already fixed directly, see `backend/internal/modules/auth/repository/
queries/users.sql`'s `UpsertUserMeetupsCompletedCache`, 2026-09-08). This
plan is the second, larger finding from that review: the recompute itself
runs synchronously inside the same transaction that closes a meetup, and its
cost doesn't scale gracefully. Reuses the outbox machinery already built for
push notifications (`docs/plans/03-hardening-pass.md` §F) — no new
infrastructure.

## Why

Today, `Close()` (a host manually closing their meetup) and `claimSweep()`
(the auto-close lifecycle sweep, up to `sweepBatchSize = 100` meetups per
tick) both call `recomputeMeetupsCompleted` — which runs
`RecomputeMeetupsCompletedForParticipants`, a correlated subquery that
re-derives each participant's *entire lifetime* completed-meetup count from
scratch — **inside the same transaction as the completion, before commit**
(`backend/internal/modules/meetup/repository/meetups_postgres.go:571-630`
and `:756-816`). Cost scales with (distinct participants across the batch) ×
(each participant's full historical completed-meetup count), and it holds
that transaction's locks for the duration. Fine today; a real bottleneck once
batch sizes or your most active hosts' histories grow — a host with
thousands of past meetups gets their whole history recounted every time any
one of their meetups closes, inside the same transaction other writes to
`meetup.meetups`/`meetup.meetup_requests` may be waiting on.

The fix pattern already exists in this codebase for exactly this shape of
problem (§F of the hardening pass, for push notifications): don't do the
expensive/external work inside the business transaction — write a small,
durable record of *intent* in the same transaction (cheap, atomic with the
completion), and let a separate poller do the expensive part afterward.
`internal/platform/outbox`'s `Store`/`Poller` are already generic
(`Row.Payload []byte` is opaque to the package — confirmed by reading
`outbox.go` directly, it never looks inside the payload), so this reuses that
package unmodified; only a second table and a second `Store` implementation
are new.

**This recompute is actually a friendlier outbox consumer than push
notifications were**: it's fully idempotent (always re-derives the true
current total from authoritative data, never a delta) and, as of the
timestamp→value guard fix, its write is safe under any amount of reordering
or redelivery. No dead-token-style cleanup, no "duplicate is a minor
annoyance" caveat needed — a duplicate delivery here is a complete no-op.

## Decision

### 1. New table: `meetup.meetups_completed_outbox`

Same shape as `meetup.notification_outbox` (migration `0003`), minus the
FCM-specific columns — this one just needs the completed meetup IDs:

```sql
CREATE TABLE meetup.meetups_completed_outbox (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  meetup_ids       UUID[] NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  processed_at     TIMESTAMPTZ,
  attempts         INT NOT NULL DEFAULT 0,
  next_attempt_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  dead_lettered_at TIMESTAMPTZ,
  last_error       TEXT
);

CREATE INDEX idx_meetups_completed_outbox_claimable
  ON meetup.meetups_completed_outbox (next_attempt_at)
  WHERE processed_at IS NULL AND dead_lettered_at IS NULL;

CREATE INDEX idx_meetups_completed_outbox_retention
  ON meetup.meetups_completed_outbox (processed_at)
  WHERE processed_at IS NOT NULL;
CREATE INDEX idx_meetups_completed_outbox_dead_lettered
  ON meetup.meetups_completed_outbox (dead_lettered_at)
  WHERE dead_lettered_at IS NOT NULL;
```

One row per completion batch (i.e. one per `Close()` call, one per
auto-close sweep tick that closed anything) — not one row per meetup. The
recompute query already batches efficiently across meetup IDs; splitting
into per-meetup rows would only mean more claim/poll overhead for no
benefit.

`internal/platform/outbox.Row.Payload` can be `meetup_ids` marshaled as JSON
(`[]string` of UUIDs) rather than relying on the poller to know this table's
native column shape — keeps the `Store` implementation's `ClaimBatch`
free to encode however is convenient, same as the notification outbox does
for its own payload today (check exactly how that one populates `Row.Payload`
from `fcm_tokens`/`title`/`body` and mirror the shape, don't invent a new
convention).

### 2. `Close()` / `claimSweep()`: replace the inline recompute with a cheap insert

Both call sites currently do:
```go
completed, err := recomputeMeetupsCompleted(ctx, q, []Meetup{closed}) // or claimed
```
before commit. Replace with a plain insert of the completed meetup IDs into
the new outbox table, same transaction, same place in the code — this is the
only change to these two functions. `recomputeMeetupsCompleted` and
`RecomputeMeetupsCompletedForParticipants` are **not deleted** — they move to
be called from the new poller's handler (§4) instead of inline here.

`r.publishMeetupsCompleted(ctx, completed)` (the post-commit publish call)
goes away from these two functions entirely — publishing now happens from
the poller after it runs the recompute, not from the closing path at all.

### 3. `Store` implementation

New file, mirroring whichever file implements `internal/platform/outbox.Store`
for `meetup.notification_outbox` today (same package, same
`ClaimBatch`/`MarkProcessed`/`MarkFailed`/`MarkDeadLettered`/`CountPending`
shape, same `FOR UPDATE SKIP LOCKED` claim query pattern, same
`next_attempt_at`-ordered partial index usage). Don't design a new claiming
strategy — copy the proven one.

### 4. New poller + handler, wired in `cmd/monolith/main.go`

A second, independent `outbox.Poller` instance (own batch size, own tick
interval — the defaults are almost certainly fine, this isn't the
network-call-bound case notifications are) whose handler:

1. Unmarshals the meetup IDs from the claimed row's payload.
2. Calls the existing, unchanged `RecomputeMeetupsCompletedForParticipants`
   query for those IDs.
3. Publishes one `eventbus.MeetupsCompletedUpdatedPayload` per resulting row,
   exactly as `recomputeMeetupsCompleted` + `publishMeetupsCompleted` do
   today — same event, same topic, same consumer
   (`internal/modules/auth/rating_consumer.go`), completely unchanged. Only
   *when* this runs changes, not what it publishes or who consumes it.
4. Returns success (→ `MarkProcessed`) or the error (→ `MarkFailed`, letting
   the poller's existing backoff/dead-letter handling apply) — no new retry
   logic to write.

### 5. Wake signal

Call this new poller's `Wake()` right after `Close()`'s and `claimSweep()`'s
transactions commit — same "near-zero latency in the common case, safety-net
tick as backstop" pattern the notification poller already uses. A profile's
completed-count updating a beat later than the completion itself is an
already-accepted trade-off in this codebase (the notification outbox
introduces the same kind of small propagation delay for pushes); this isn't
a new kind of inconsistency, just the same pattern applied to a second
topic.

### 6. Retention

Extend the existing retention job (§F8 of the hardening pass) to also sweep
`meetup.meetups_completed_outbox` — same processed/dead-lettered retention
windows, same batched-delete shape. If the retention job is already written
generically enough to take a table name as a parameter, this should be a
one-line addition, not new logic; check before writing a second copy of it.

## Tests

- `Store` implementation: claim/mark-processed/mark-failed/mark-dead-lettered,
  plus the concurrent-claimers-never-overlap test — same coverage the
  notification outbox's `Store` already has, same test shape.
- Poller handler: given a claimed row naming N meetup IDs, confirm it calls
  the recompute query and publishes the right events; confirm a query error
  surfaces as a poller failure (→ retry), not a swallowed error.
- `Close()`/`claimSweep()`: update existing tests to assert an outbox row is
  inserted with the correct meetup IDs, **not** that
  `MeetupsCompletedUpdatedPayload` events are published synchronously —
  that assertion moves to the poller-handler tests instead. Grep for every
  existing test asserting synchronous publish-on-close and update it
  deliberately (same discipline as every prior round's "existing test values
  that changed" table) — don't leave one contradicting the new design next to
  a passing new test.
- Integration test: close a meetup for real, confirm the outbox row appears
  and `meetups_completed` is still 0 until the poller runs, run one poller
  tick, confirm the profile cache is now updated. This is the test that
  actually proves the async handoff works end to end, not just that each
  half works in isolation.
- Re-run `TestMeetupsCompleted_CountsAccumulateAndAreAbsolute` against the
  new path (it currently exercises the synchronous path directly) — same
  assertion (`[1, 2, 3]`, not `[1,1,1]` or `[1,3,6]`), now via the outbox +
  poller instead of inline.

## When done

Same bar as every prior round — file:line, not assertions. In particular:
confirm (by grep, quoted in the report) that `Close()` and `claimSweep()` no
longer call `recomputeMeetupsCompleted`/`RecomputeMeetupsCompletedForParticipants`
directly; confirm the new poller's `Wake()` is actually called at both commit
points (this exact class of bug — a poller built but never woken — was
self-found and fixed once already in the notification outbox work, so check
for it explicitly rather than assuming it was done); confirm the retention
job covers the new table; confirm `go build`/`go vet`/`golangci-lint`/
`go test ./... -race` all pass.
