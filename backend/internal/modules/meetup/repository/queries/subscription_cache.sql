-- name: UpsertSubscriptionCache :execrows
-- The subscription-activated/subscription-deactivated consumer's
-- idempotent, order-guarded upsert — same shape as user_display_cache.sql's
-- UpsertUserDisplayCache. ON CONFLICT DO UPDATE handles redelivery safely;
-- the WHERE clause is the ordering guard, applying unconditionally on first
-- insert, otherwise only if this event is strictly newer than what is
-- already stored. Rows affected (0 or 1) tells the caller whether the guard
-- skipped a stale event, purely for logging.
--
-- Generated through sqlc here, unlike the source, whose own
-- subscription_cache_postgres.go hand-writes this as raw pgx with a comment
-- saying the sqlc CLI "wasn't available in this environment at
-- implementation time... worth regenerating through sqlcgen for real once
-- the CLI is available". It is available here, so this is that.
INSERT INTO meetup.subscription_cache (user_id, tier, entitled, updated_at)
VALUES (sqlc.arg(user_id), sqlc.arg(tier), sqlc.arg(entitled), sqlc.arg(updated_at))
ON CONFLICT (user_id) DO UPDATE
SET tier = excluded.tier,
    entitled = excluded.entitled,
    updated_at = excluded.updated_at
WHERE excluded.updated_at > meetup.subscription_cache.updated_at;

-- name: IsSubscriptionEntitled :one
-- A user never seen by either event has no row at all — the caller maps
-- pgx.ErrNoRows to false (free/not-entitled), which is the safe default,
-- not an error.
SELECT entitled FROM meetup.subscription_cache WHERE user_id = $1;
