-- name: UpsertUserLocationCache :execrows
-- The user-location-updated consumer's idempotent, order-guarded upsert —
-- same shape as meetup.user_display_cache.sql's UpsertUserDisplayCache (ADR-018
-- Decision 2). ON CONFLICT DO UPDATE handles redelivery of the same event
-- safely; the WHERE clause on the DO UPDATE is the ordering guard.
INSERT INTO meetup.user_location_cache (user_id, lat, lng, updated_at)
VALUES (sqlc.arg(user_id), sqlc.arg(lat), sqlc.arg(lng), sqlc.arg(updated_at))
ON CONFLICT (user_id) DO UPDATE
SET lat = excluded.lat,
    lng = excluded.lng,
    updated_at = excluded.updated_at
WHERE excluded.updated_at > meetup.user_location_cache.updated_at;

-- name: ListUserLocationCacheWithinRadius :many
-- Backs the meetup-created consumer's nearby-notification fan-out
-- (backend/geo-visibility-and-nearby-notifications-PLAN.md Step 4) — same
-- ST_DWithin condition as ListOpenMeetupsByIntentFirstPage (meetup.meetups.sql),
-- rewritten from a plain haversine expression to real PostGIS per
-- ADR-027, now against this cache table instead of the viewer's own
-- fresh coordinate. sqlc.arg(not_before) bounds staleness (Step 4: "non-
-- stale, updated_at within 24 hours") — a cache row older than that is
-- excluded rather than notifying someone about a meetup near where they
-- used to be.
--
-- LIMIT 500 (2026-08-31 round-3 hardening) — a backstop cap even with a
-- real GiST index doing the heavy lifting: a single meetup notifying more
-- than 500 nearby users in one fan-out is worth capping regardless of how
-- fast the lookup itself is.
SELECT user_id, lat, lng, updated_at
FROM meetup.user_location_cache
WHERE updated_at > sqlc.arg(not_before)::timestamptz
  AND ST_DWithin(
    location,
    ST_SetSRID(ST_MakePoint(sqlc.arg(center_lng)::float8, sqlc.arg(center_lat)::float8), 4326)::geography,
    50000
  )
LIMIT 500;
