-- name: EnqueueMeetupsCompleted :exec
-- The outbox insert, executed on the SAME transaction handle as the close or
-- the auto-close claim it accompanies. That co-location is the entire point,
-- exactly as with EnqueueNotification: the completion and the record of
-- "someone must recompute totals for these" either both commit or neither
-- does. There is no window in which a meetup is completed but its recompute
-- was never scheduled.
--
-- Cheap by construction — one INSERT of an array of ids — which is what
-- takes the expensive recompute off the closing transaction.
INSERT INTO meetup.meetups_completed_outbox (meetup_ids)
VALUES (sqlc.arg(meetup_ids)::uuid[]);

-- name: ClaimMeetupsCompletedOutboxBatch :many
-- Claims up to batch_size due rows. Deliberately IDENTICAL in shape to
-- ClaimNotificationOutboxBatch — the proven claiming strategy, not a second
-- design.
--
-- It is an UPDATE rather than a SELECT ... FOR UPDATE SKIP LOCKED held for
-- the duration of processing, for the same reason as the notification
-- version: stamping next_attempt_at into the future gives each claimed row a
-- VISIBILITY TIMEOUT, so it leaves the claimable set the instant this
-- commits and a second poller skips it without needing to know who is
-- working on it. Crash recovery follows for free — a claimer that dies
-- records no outcome, and the row becomes due again when the timeout lapses.
-- No lease table, no stuck-claim reaper.
--
-- (The notification version's stronger motivation — never hold a Postgres
-- transaction open across a third-party HTTP call — does not apply here,
-- since this processing is database-only. The pattern is kept anyway: the
-- concurrency guarantees are the ones that matter, an earlier draft of the
-- notification query that released the lock WITHOUT the stamp was caught by
-- its concurrency test claiming rows two and three times, and having one
-- claiming strategy in this codebase rather than two is worth more than
-- micro-optimising the second one.)
--
-- attempts is incremented at CLAIM time, not on failure, so a row that
-- crashes its claimer mid-flight still counts against the retry ceiling
-- instead of being retried forever. MarkMeetupsCompletedFailed therefore
-- sets the backoff deadline without incrementing again.
--
-- ORDER BY next_attempt_at matches idx_meetups_completed_outbox_claimable.
UPDATE meetup.meetups_completed_outbox
SET attempts = attempts + 1,
    next_attempt_at = now() + sqlc.arg(visibility_timeout)::interval
WHERE id IN (
  SELECT id FROM meetup.meetups_completed_outbox
  WHERE processed_at IS NULL
    AND dead_lettered_at IS NULL
    AND next_attempt_at <= now()
  ORDER BY next_attempt_at
  LIMIT sqlc.arg(batch_size)
  FOR UPDATE SKIP LOCKED
)
RETURNING id, meetup_ids, attempts;

-- name: MarkMeetupsCompletedProcessed :exec
-- The only statement that ever writes processed_at.
UPDATE meetup.meetups_completed_outbox
SET processed_at = now(), last_error = NULL
WHERE id = sqlc.arg(id);

-- name: MarkMeetupsCompletedFailed :exec
-- A retryable failure: pull next_attempt_at back from the visibility timeout
-- to the real backoff deadline and record why. processed_at is untouched, so
-- the row stays pending by construction. attempts is NOT incremented here —
-- the claim already did that.
UPDATE meetup.meetups_completed_outbox
SET next_attempt_at = sqlc.arg(next_attempt_at)::timestamptz,
    last_error = sqlc.arg(last_error)
WHERE id = sqlc.arg(id);

-- name: MarkMeetupsCompletedDeadLettered :exec
-- Terminal. Leaves the claimable partial index and is never attempted again,
-- but the row is kept: a permanent failure here means some users' profile
-- counts are silently stale, which is exactly the thing someone should be
-- able to find and fix.
UPDATE meetup.meetups_completed_outbox
SET dead_lettered_at = now(),
    last_error = sqlc.arg(last_error)
WHERE id = sqlc.arg(id);

-- name: DeleteProcessedMeetupsCompleted :execrows
-- Retention for done rows, batched via the id subquery rather than one
-- unbounded DELETE — same reasoning as DeleteProcessedNotifications. The
-- caller loops until a batch comes back short.
DELETE FROM meetup.meetups_completed_outbox
WHERE id IN (
  SELECT id FROM meetup.meetups_completed_outbox
  WHERE processed_at IS NOT NULL AND processed_at < sqlc.arg(older_than)::timestamptz
  LIMIT sqlc.arg(batch_size)
);

-- name: DeleteDeadLetteredMeetupsCompleted :execrows
-- Retention for dead-lettered rows, kept longer than successes on purpose.
DELETE FROM meetup.meetups_completed_outbox
WHERE id IN (
  SELECT id FROM meetup.meetups_completed_outbox
  WHERE dead_lettered_at IS NOT NULL AND dead_lettered_at < sqlc.arg(older_than)::timestamptz
  LIMIT sqlc.arg(batch_size)
);

-- name: CountPendingMeetupsCompleted :one
-- Backs the pending gauge. Same predicate as the claimable partial index, so
-- it is an index-only scan over the pending set rather than a table scan.
SELECT count(*) FROM meetup.meetups_completed_outbox
WHERE processed_at IS NULL AND dead_lettered_at IS NULL;
