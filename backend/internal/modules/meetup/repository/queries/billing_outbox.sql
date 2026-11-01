-- meetup.billing_outbox: charged meetups' created, cancelled and closed
-- events, written in the same transaction as the change (plan 29 §3.5,
-- §3.6). Same claiming strategy as the other meetup outboxes.

-- name: InsertBillingEvent :exec
INSERT INTO meetup.billing_outbox (topic, payload) VALUES (sqlc.arg(topic), sqlc.arg(payload));

-- name: ClaimBillingOutboxBatch :many
UPDATE meetup.billing_outbox
SET attempts = attempts + 1,
    next_attempt_at = now() + sqlc.arg(visibility_timeout)::interval
WHERE id IN (
  SELECT id FROM meetup.billing_outbox
  WHERE processed_at IS NULL AND dead_lettered_at IS NULL AND next_attempt_at <= now()
  ORDER BY next_attempt_at
  LIMIT sqlc.arg(batch_size)
  FOR UPDATE SKIP LOCKED
)
RETURNING id, topic, payload, attempts;

-- name: MarkBillingEventProcessed :exec
UPDATE meetup.billing_outbox SET processed_at = now(), last_error = NULL WHERE id = sqlc.arg(id);

-- name: MarkBillingEventFailed :exec
UPDATE meetup.billing_outbox
SET next_attempt_at = sqlc.arg(next_attempt_at)::timestamptz, last_error = sqlc.arg(last_error)
WHERE id = sqlc.arg(id);

-- name: MarkBillingEventDeadLettered :exec
UPDATE meetup.billing_outbox SET dead_lettered_at = now(), last_error = sqlc.arg(last_error)
WHERE id = sqlc.arg(id);

-- name: CountPendingBillingEvents :one
SELECT count(*) FROM meetup.billing_outbox WHERE processed_at IS NULL AND dead_lettered_at IS NULL;

-- name: DeleteProcessedBillingEvents :execrows
DELETE FROM meetup.billing_outbox
WHERE id IN (
  SELECT id FROM meetup.billing_outbox
  WHERE processed_at IS NOT NULL AND processed_at < sqlc.arg(older_than)::timestamptz
  LIMIT sqlc.arg(batch_size)
);

-- name: DeleteDeadLetteredBillingEvents :execrows
DELETE FROM meetup.billing_outbox
WHERE id IN (
  SELECT id FROM meetup.billing_outbox
  WHERE dead_lettered_at IS NOT NULL AND dead_lettered_at < sqlc.arg(older_than)::timestamptz
  LIMIT sqlc.arg(batch_size)
);
