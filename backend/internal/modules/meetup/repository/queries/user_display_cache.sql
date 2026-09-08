-- name: UpsertUserDisplayCache :execrows
-- The user-onboarded/user-profile-updated consumer's idempotent,
-- order-guarded upsert (ADR-018 Decision 2, ADR-017's addendum Step 4).
-- ON CONFLICT DO UPDATE handles redelivery of the same event safely; the
-- WHERE clause on the DO UPDATE is the ordering guard — applies
-- unconditionally on first insert, otherwise only if this event is
-- strictly newer than what's already stored. Rows affected (0 or 1) tells
-- the caller whether the guard actually skipped a stale/out-of-order
-- event, purely for logging.
INSERT INTO meetup.user_display_cache (user_id, full_name, profile_photo_url, trust_level, updated_at)
VALUES (sqlc.arg(user_id), sqlc.arg(full_name), sqlc.arg(profile_photo_url), sqlc.arg(trust_level), sqlc.arg(updated_at))
ON CONFLICT (user_id) DO UPDATE
SET full_name = excluded.full_name,
    profile_photo_url = excluded.profile_photo_url,
    trust_level = excluded.trust_level,
    updated_at = excluded.updated_at
WHERE excluded.updated_at > meetup.user_display_cache.updated_at;
