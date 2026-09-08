-- name: EnqueueNotification :exec
-- The outbox insert (§F3). Always executed on a transaction handle that is
-- ALSO carrying the business write it accompanies — that co-location is the
-- entire point: the accept/reject/cancel/close and the notification it
-- implies either both commit or neither does. A crash between them is not a
-- window that has to be tolerated; it is a state the database will not
-- produce.
INSERT INTO meetup.notification_outbox (fcm_tokens, title, body, data)
VALUES (sqlc.arg(fcm_tokens)::text[], sqlc.arg(title), sqlc.arg(body), sqlc.arg(data));

-- name: ClaimNotificationOutboxBatch :many
-- Claims up to $1 due rows for delivery.
--
-- THIS IS AN UPDATE, NOT A SELECT, AND THAT IS THE WHOLE POINT. The obvious
-- implementation — SELECT ... FOR UPDATE SKIP LOCKED, then process, then
-- record the outcome — only works if the lock is HELD for the whole of the
-- caller's processing. It cannot be here: processing means an FCM round trip
-- over the network, and holding a Postgres transaction open across a
-- third-party HTTP call is how a slow vendor turns into an exhausted
-- connection pool. A degraded FCM must not be able to take the database with
-- it.
--
-- So the claim has to survive the lock being released, which means writing
-- something. Stamping next_attempt_at into the future gives each claimed row
-- a VISIBILITY TIMEOUT: it leaves the claimable set the instant this
-- statement commits, so a second poller (or the next tick of this one) skips
-- it without needing to know anything about who is working on it. An earlier
-- version of this query released the lock without the stamp, and the
-- concurrency test caught the result immediately — with four concurrent
-- claimers, rows were being claimed two and three times each, which in
-- production is the same user receiving the same push two and three times.
--
-- FOR UPDATE SKIP LOCKED in the subquery is still load-bearing: it is what
-- makes two claimers running this statement at the same moment take DISJOINT
-- rows rather than one blocking on the other.
--
-- Crash recovery follows from the same stamp. A claimer that dies
-- mid-delivery records no outcome, so its rows simply become due again once
-- the visibility timeout lapses and the next poll picks them up. Nothing has
-- to detect the crash, and there is no lease table or stuck-claim reaper to
-- get wrong.
--
-- attempts is incremented HERE, at claim time, rather than on failure. That
-- is deliberate: a delivery that crashes the process mid-flight must still
-- count against the retry ceiling, or a row that reliably kills its claimer
-- is retried forever. Marking failed afterwards therefore sets the backoff
-- deadline but does not increment again.
--
-- ORDER BY next_attempt_at matches idx_notification_outbox_claimable exactly
-- (see the migration) — ordering by created_at would force an unindexed sort
-- that degrades as the pending set grows. Explicit column list rather than *.
UPDATE meetup.notification_outbox
SET attempts = attempts + 1,
    next_attempt_at = now() + sqlc.arg(visibility_timeout)::interval
WHERE id IN (
  SELECT id FROM meetup.notification_outbox
  WHERE processed_at IS NULL
    AND dead_lettered_at IS NULL
    AND next_attempt_at <= now()
  ORDER BY next_attempt_at
  LIMIT sqlc.arg(batch_size)
  FOR UPDATE SKIP LOCKED
)
RETURNING id, fcm_tokens, title, body, data, attempts;

-- name: MarkNotificationProcessed :exec
-- The only statement that ever writes processed_at. Success is the sole path
-- to it, which is what lets "processed_at IS NULL" mean "not yet delivered"
-- without a status column to keep consistent.
UPDATE meetup.notification_outbox
SET processed_at = now(), last_error = NULL
WHERE id = sqlc.arg(id);

-- name: MarkNotificationFailed :exec
-- A retryable failure: pull the row's next attempt back from the visibility
-- timeout to its real backoff deadline, and record why. processed_at is
-- untouched, so the row stays pending by construction.
--
-- attempts is NOT incremented here — ClaimNotificationOutboxBatch already
-- did that when it handed the row out. Incrementing in both places would
-- double-count every failure and halve the effective retry budget.
UPDATE meetup.notification_outbox
SET next_attempt_at = sqlc.arg(next_attempt_at)::timestamptz,
    last_error = sqlc.arg(last_error)
WHERE id = sqlc.arg(id);

-- name: MarkNotificationDeadLettered :exec
-- Terminal. The row leaves the claimable partial index (which excludes
-- dead_lettered_at IS NOT NULL) and is never attempted again, but is kept —
-- a permanent delivery failure is evidence someone should look at, not
-- something to erase on the spot. The retention job keeps these far longer
-- than successes for exactly that reason.
UPDATE meetup.notification_outbox
SET dead_lettered_at = now(),
    last_error = sqlc.arg(last_error)
WHERE id = sqlc.arg(id);

-- name: DeleteProcessedNotifications :execrows
-- Retention for delivered rows (§F8). Batched via the id subquery rather
-- than one unbounded DELETE: the first run after this ships (or after the
-- job has been off for a while) could face a large backlog, and a single
-- statement would hold one long transaction and a correspondingly long lock.
-- The caller loops until a batch comes back short.
DELETE FROM meetup.notification_outbox
WHERE id IN (
  SELECT id FROM meetup.notification_outbox
  WHERE processed_at IS NOT NULL AND processed_at < sqlc.arg(older_than)::timestamptz
  LIMIT sqlc.arg(batch_size)
);

-- name: DeleteDeadLetteredNotifications :execrows
-- Retention for dead-lettered rows (§F8), kept longer than successes on
-- purpose — see MarkNotificationDeadLettered.
DELETE FROM meetup.notification_outbox
WHERE id IN (
  SELECT id FROM meetup.notification_outbox
  WHERE dead_lettered_at IS NOT NULL AND dead_lettered_at < sqlc.arg(older_than)::timestamptz
  LIMIT sqlc.arg(batch_size)
);

-- name: CountPendingNotifications :one
-- Backs the notification_outbox_pending gauge. Uses the same predicate as
-- the claimable partial index so it is an index-only scan over the pending
-- set, not a table scan.
SELECT count(*) FROM meetup.notification_outbox
WHERE processed_at IS NULL AND dead_lettered_at IS NULL;
