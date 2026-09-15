-- name: UpsertDeviceToken :one
-- Upserts by token, not by user — a token identifies one physical device
-- install; re-registering it under a different account reassigns
-- ownership rather than leaving a stale row.
INSERT INTO meetup.device_tokens (user_id, fcm_token)
VALUES ($1, $2)
ON CONFLICT (fcm_token) DO UPDATE SET user_id = $1, updated_at = now()
RETURNING *;

-- name: ListDeviceTokensForUser :many
SELECT * FROM meetup.device_tokens WHERE user_id = $1;

-- name: ListDeviceTokensForUsers :many
-- Batched form of ListDeviceTokensForUser (2026-08-31 round-3 hardening,
-- internal/notifications.BatchSender) — one query for all of a fan-out's
-- recipients instead of one per recipient. user_id is part of the SELECT
-- list (not just fcm_token) so the caller can group rows back by user
-- without a second lookup.
SELECT * FROM meetup.device_tokens WHERE user_id = ANY(sqlc.arg(user_ids)::uuid[]);

-- name: DeleteDeviceToken :exec
-- Removes a device token FCM has reported as permanently unregistered
-- (docs/plans/03-hardening-pass.md §E2c) — app uninstalled, token rotated,
-- or wrong Firebase project. Keyed by the token itself, not by user: the
-- token identifies one physical device install, and it is the device that
-- is gone.
--
-- Idempotent: deleting a token that is already gone affects zero rows and is
-- not an error. Two concurrent deliveries can both learn the same token is
-- dead, and neither should fail because the other got there first.
DELETE FROM meetup.device_tokens WHERE fcm_token = $1;

-- name: DeleteDeviceTokenForUser :execrows
-- The sign-out path: removes the caller's OWN registration of a token.
-- Scoped to user_id as well as token so a signed-out account can never
-- silence a device that a different account has since claimed (the upsert
-- above reassigns ownership on sign-in); if the row is no longer theirs,
-- zero rows match and nothing changes.
DELETE FROM meetup.device_tokens WHERE fcm_token = $1 AND user_id = $2;
