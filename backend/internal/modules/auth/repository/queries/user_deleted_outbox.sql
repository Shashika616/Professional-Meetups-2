-- name: EnqueueUserDeleted :exec
-- Written in the SAME transaction as the delete of auth.users — see
-- 0015_user_deleted_outbox.up.sql for why that is the whole point.
INSERT INTO auth.user_deleted_outbox (user_id) VALUES ($1);

-- name: ClaimUserDeletedOutboxBatch :many
-- Same claim as ClaimMeetupsCompletedOutboxBatch: bump attempts and push
-- next_attempt_at out by the visibility timeout, so a crashed claimer's rows
-- come back on their own and two pollers never take the same row.
UPDATE auth.user_deleted_outbox
SET attempts = attempts + 1,
    next_attempt_at = now() + sqlc.arg(visibility_timeout)::interval
WHERE id IN (
  SELECT id FROM auth.user_deleted_outbox
  WHERE processed_at IS NULL
    AND dead_lettered_at IS NULL
    AND next_attempt_at <= now()
  ORDER BY next_attempt_at
  LIMIT sqlc.arg(batch_size)
  FOR UPDATE SKIP LOCKED
)
RETURNING id, user_id, attempts;

-- name: MarkUserDeletedProcessed :exec
UPDATE auth.user_deleted_outbox
SET processed_at = now(), last_error = NULL
WHERE id = sqlc.arg(id);

-- name: MarkUserDeletedFailed :exec
UPDATE auth.user_deleted_outbox
SET next_attempt_at = sqlc.arg(next_attempt_at)::timestamptz,
    last_error = sqlc.arg(last_error)
WHERE id = sqlc.arg(id);

-- name: MarkUserDeletedDeadLettered :exec
UPDATE auth.user_deleted_outbox
SET dead_lettered_at = now(),
    last_error = sqlc.arg(last_error)
WHERE id = sqlc.arg(id);

-- name: DeleteProcessedUserDeleted :execrows
DELETE FROM auth.user_deleted_outbox
WHERE id IN (
  SELECT id FROM auth.user_deleted_outbox
  WHERE processed_at IS NOT NULL AND processed_at < sqlc.arg(older_than)::timestamptz
  LIMIT sqlc.arg(batch_size)
);

-- name: DeleteDeadLetteredUserDeleted :execrows
DELETE FROM auth.user_deleted_outbox
WHERE id IN (
  SELECT id FROM auth.user_deleted_outbox
  WHERE dead_lettered_at IS NOT NULL AND dead_lettered_at < sqlc.arg(older_than)::timestamptz
  LIMIT sqlc.arg(batch_size)
);

-- name: CountPendingUserDeleted :one
SELECT count(*) FROM auth.user_deleted_outbox
WHERE processed_at IS NULL AND dead_lettered_at IS NULL;
