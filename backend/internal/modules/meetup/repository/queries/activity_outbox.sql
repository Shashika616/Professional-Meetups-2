-- meetup.activity_outbox: join requests and accepts, for analytics (plan 29D),
-- written in the same transaction as the request or the accept.

-- name: InsertActivityEvent :exec
INSERT INTO meetup.activity_outbox (topic, payload) VALUES (sqlc.arg(topic), sqlc.arg(payload));

-- name: ClaimActivityOutboxBatch :many
UPDATE meetup.activity_outbox
SET attempts = attempts + 1,
    next_attempt_at = now() + sqlc.arg(visibility_timeout)::interval
WHERE id IN (
  SELECT id FROM meetup.activity_outbox
  WHERE processed_at IS NULL AND dead_lettered_at IS NULL AND next_attempt_at <= now()
  ORDER BY next_attempt_at
  LIMIT sqlc.arg(batch_size)
  FOR UPDATE SKIP LOCKED
)
RETURNING id, topic, payload, attempts;

-- name: MarkActivityEventProcessed :exec
UPDATE meetup.activity_outbox SET processed_at = now(), last_error = NULL WHERE id = sqlc.arg(id);

-- name: MarkActivityEventFailed :exec
UPDATE meetup.activity_outbox
SET next_attempt_at = sqlc.arg(next_attempt_at)::timestamptz, last_error = sqlc.arg(last_error)
WHERE id = sqlc.arg(id);

-- name: MarkActivityEventDeadLettered :exec
UPDATE meetup.activity_outbox SET dead_lettered_at = now(), last_error = sqlc.arg(last_error)
WHERE id = sqlc.arg(id);

-- name: CountPendingActivityEvents :one
SELECT count(*) FROM meetup.activity_outbox WHERE processed_at IS NULL AND dead_lettered_at IS NULL;

-- name: DeleteProcessedActivityEvents :execrows
DELETE FROM meetup.activity_outbox
WHERE id IN (
  SELECT id FROM meetup.activity_outbox
  WHERE processed_at IS NOT NULL AND processed_at < sqlc.arg(older_than)::timestamptz
  LIMIT sqlc.arg(batch_size)
);

-- name: DeleteDeadLetteredActivityEvents :execrows
DELETE FROM meetup.activity_outbox
WHERE id IN (
  SELECT id FROM meetup.activity_outbox
  WHERE dead_lettered_at IS NOT NULL AND dead_lettered_at < sqlc.arg(older_than)::timestamptz
  LIMIT sqlc.arg(batch_size)
);
