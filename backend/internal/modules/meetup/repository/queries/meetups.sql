-- name: CreateMeetup :one
INSERT INTO meetup.meetups (host_user_id, intent, window_start, window_end, location_lat, location_lng, location_label, capacity)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
RETURNING *;

-- name: GetMeetupByID :one
-- my_request_status is the *latest* request this specific user (viewerID)
-- has made on this meetup, or NULL if they never requested — the frontend
-- uses this to render "REQUEST TO JOIN" vs. the request's current status
-- (frontend/meetup-scheduling-PLAN.md Step 3). Plain LEFT JOIN + ORDER BY
-- ... LIMIT 1, not a scalar subquery or LEFT JOIN LATERAL in the SELECT
-- list — sqlc's nullability analysis correctly infers a plain LEFT JOIN
-- column as nullable (NullMeetupRequestStatus); both of the other two forms
-- were confirmed (by generating each and inspecting the output) to produce
-- a non-nullable Go type that would panic scanning a real NULL row — a
-- viewer who's never requested to join, the common browsing case.
--
-- Host display info comes from user_display_cache, not a live JOIN users
-- (ADR-017's addendum — users is a different database now). LEFT JOIN, not
-- JOIN — deliberately, a deviation from the plan's literal "same shape":
-- user_display_cache has no FK to enforce a row exists, and is populated
-- asynchronously by a Pub/Sub consumer (Step 6), so a meetup hosted by a
-- just-onboarded user could briefly have no cache row yet. An inner JOIN
-- would make such a meetup vanish from GetMeetupByID/listings entirely
-- until the consumer catches up; LEFT JOIN + COALESCE just shows blank
-- display fields for that brief window instead — the meetup itself is
-- never at risk of disappearing due to eventual-consistency lag.
--
-- rating_average/rating_count are a live aggregate over this service's own
-- meetup_user_ratings, not a cached column (Step 4's note: "meetup already
-- has them locally... nothing to cache back to itself") — cross-joined via
-- a LATERAL subquery so an unrated host correctly gets 0/0 rather than
-- disappearing from a plain JOIN.
SELECT
  m.*,
  COALESCE(u.full_name, '') AS host_full_name,
  u.profile_photo_url AS host_profile_photo_url,
  COALESCE(u.trust_level, 0) AS host_trust_level,
  COALESCE(ratings.rating_average, 0)::numeric(3,2) AS host_rating_average,
  COALESCE(ratings.rating_count, 0)::int AS host_rating_count,
  (SELECT count(*) FROM meetup.meetup_requests r2 WHERE r2.meetup_id = m.id AND r2.status = 'accepted') AS accepted_count,
  r.status AS my_request_status,
  -- Added for the requester-side withdraw action (ADR-020 §4) — WithdrawRequest
  -- takes a request id, and this was the only Meetup-shaped query the
  -- viewer's own request id wasn't already available on for free (it's
  -- just r.id, the same LEFT JOINed row my_request_status already reads).
  r.id AS my_request_id
FROM meetup.meetups m
LEFT JOIN meetup.user_display_cache u ON u.user_id = m.host_user_id
LEFT JOIN LATERAL (
  SELECT ROUND(AVG(score), 2) AS rating_average, count(*) AS rating_count
  FROM meetup.meetup_user_ratings mr WHERE mr.rated_user_id = m.host_user_id
) ratings ON true
LEFT JOIN meetup.meetup_requests r ON r.meetup_id = m.id AND r.requester_id = $2
WHERE m.id = $1
ORDER BY r.created_at DESC NULLS LAST
LIMIT 1;

-- name: GetMeetupByIDForUpdate :one
-- Plain, no join — used only inside AcceptRequest's transaction to lock the
-- row and re-check status/capacity, host display info is irrelevant there.
SELECT * FROM meetup.meetups WHERE id = $1 FOR UPDATE;

-- name: ListOpenMeetupsFirstPage :many
-- DISTINCT ON (m.id) + a wrapping SELECT to re-sort by recency: DISTINCT ON
-- requires its own ORDER BY to start with the same expression(s), which
-- would otherwise force sorting this page by id instead of created_at —
-- the inner query dedupes (a requester can have multiple historical
-- meetup_requests rows for the same meetup, see ListMeetupsRequestedByUser
-- above), the outer one restores the intended pagination order. Plain LEFT
-- JOIN (not LATERAL/a scalar subquery) for my_request_status, same
-- nullability reasoning as GetMeetupByID above. See GetMeetupByID for why
-- user_display_cache/meetup_user_ratings are both LEFT JOINed.
--
-- The ST_DWithin distance condition in WHERE (ADR-021 §2 originally,
-- rewritten from a plain haversine expression to real PostGIS per
-- ADR-027) runs alongside idx_meetups_intent_status's own narrowing of
-- m.status/m.intent — the two conditions each use their own index
-- (idx_meetups_intent_status, idx_meetups_location_gist), not one
-- replacing the other. 40000 = 40km in meters (ST_DWithin on geography
-- takes meters, not degrees).
--
-- The viewer's OWN hosted meetups are exempt from that radius: a host who
-- scheduled a meetup outside their own current 40km bubble (travelling, or
-- scheduling somewhere they'll be later) otherwise couldn't see their own
-- meetup on the browse feed at all, even though _MeetupCard already has a
-- "YOU'RE HOSTING" state ready for exactly that row. This deliberately
-- reuses sqlc.arg(requester_id) — already bound to the viewer's id for the my_request_status
-- LEFT JOIN below — rather than adding a new bound parameter, so no
-- caller/param struct changes: the same value simply does double duty.
-- Scoped to hosts only; a meetup the viewer merely has an accepted request
-- for is NOT exempted here (it already surfaces distance-unfiltered via
-- "Your Meetups"/Active Meetups).
WITH deduped AS (
  SELECT DISTINCT ON (m.id)
    m.*,
    COALESCE(u.full_name, '') AS host_full_name,
    u.profile_photo_url AS host_profile_photo_url,
    COALESCE(u.trust_level, 0) AS host_trust_level,
    COALESCE(ratings.rating_average, 0)::numeric(3,2) AS host_rating_average,
    COALESCE(ratings.rating_count, 0)::int AS host_rating_count,
    (SELECT count(*) FROM meetup.meetup_requests r2 WHERE r2.meetup_id = m.id AND r2.status = 'accepted') AS accepted_count,
    r.status AS my_request_status
  FROM meetup.meetups m
  LEFT JOIN meetup.user_display_cache u ON u.user_id = m.host_user_id
  LEFT JOIN LATERAL (
    SELECT ROUND(AVG(score), 2) AS rating_average, count(*) AS rating_count
    FROM meetup.meetup_user_ratings mr WHERE mr.rated_user_id = m.host_user_id
  ) ratings ON true
  LEFT JOIN meetup.meetup_requests r ON r.meetup_id = m.id AND r.requester_id = sqlc.arg(requester_id)
  WHERE m.status = 'open'
    -- Both filters below are OPTIONAL and default to today's exact
    -- behaviour when unset, so every pre-existing caller is unaffected.
    --
    -- intent NULL = every intent (the home screen's "All" chip). Expressed
    -- as a NULL check rather than a separate query so there is one place
    -- where "which open meetups is this viewer allowed to see" is decided —
    -- a second near-identical query is how the ST_DWithin exemption below
    -- would eventually drift between them.
    AND (sqlc.narg(intent)::meetup.intent_type IS NULL OR m.intent = sqlc.narg(intent)::meetup.intent_type)
    -- within_days 0 = unrestricted. > 0 caps how far out window_start may
    -- be, which is what makes a "Happening Soon" view possible; nothing in
    -- this module supported a date-range filter before.
    AND (sqlc.arg(within_days)::int = 0
         OR m.window_start <= now() + (sqlc.arg(within_days)::int * INTERVAL '1 day'))
    AND (
      m.host_user_id = sqlc.arg(requester_id)
      OR ST_DWithin(
        m.location,
        ST_SetSRID(ST_MakePoint(sqlc.arg(viewer_lng)::float8, sqlc.arg(viewer_lat)::float8), 4326)::geography,
        40000
      )
    )
  ORDER BY m.id, r.created_at DESC NULLS LAST
)
SELECT * FROM deduped
ORDER BY created_at DESC, id DESC
LIMIT sqlc.arg(page_limit);

-- name: ListOpenMeetupsAfterCursor :many
-- Keyset pagination on (created_at, id) — cursorCreatedAt/cursorID are the
-- last row of the previous page, so this resumes strictly after it. Row
-- comparison (a, b) < (c, d) is a single index-friendly condition, not a
-- chain of ORs. Same DISTINCT-then-re-sort shape as the first-page query
-- above, for the same reason. See that query's comment for the
-- ST_DWithin condition below, and for why the viewer's own hosted meetups
-- (m.host_user_id = requester_id) are exempt from the 40km radius — the exemption
-- must stay identical in both queries, or a host's own out-of-range meetup
-- would appear on page 1 and then vanish from page 2 onward.
WITH deduped AS (
  SELECT DISTINCT ON (m.id)
    m.*,
    COALESCE(u.full_name, '') AS host_full_name,
    u.profile_photo_url AS host_profile_photo_url,
    COALESCE(u.trust_level, 0) AS host_trust_level,
    COALESCE(ratings.rating_average, 0)::numeric(3,2) AS host_rating_average,
    COALESCE(ratings.rating_count, 0)::int AS host_rating_count,
    (SELECT count(*) FROM meetup.meetup_requests r2 WHERE r2.meetup_id = m.id AND r2.status = 'accepted') AS accepted_count,
    r.status AS my_request_status
  FROM meetup.meetups m
  LEFT JOIN meetup.user_display_cache u ON u.user_id = m.host_user_id
  LEFT JOIN LATERAL (
    SELECT ROUND(AVG(score), 2) AS rating_average, count(*) AS rating_count
    FROM meetup.meetup_user_ratings mr WHERE mr.rated_user_id = m.host_user_id
  ) ratings ON true
  LEFT JOIN meetup.meetup_requests r ON r.meetup_id = m.id AND r.requester_id = sqlc.arg(requester_id)
  WHERE m.status = 'open'
    -- Both filters below are OPTIONAL and default to today's exact
    -- behaviour when unset, so every pre-existing caller is unaffected.
    --
    -- intent NULL = every intent (the home screen's "All" chip). Expressed
    -- as a NULL check rather than a separate query so there is one place
    -- where "which open meetups is this viewer allowed to see" is decided —
    -- a second near-identical query is how the ST_DWithin exemption below
    -- would eventually drift between them.
    AND (sqlc.narg(intent)::meetup.intent_type IS NULL OR m.intent = sqlc.narg(intent)::meetup.intent_type)
    -- within_days 0 = unrestricted. > 0 caps how far out window_start may
    -- be, which is what makes a "Happening Soon" view possible; nothing in
    -- this module supported a date-range filter before.
    AND (sqlc.arg(within_days)::int = 0
         OR m.window_start <= now() + (sqlc.arg(within_days)::int * INTERVAL '1 day'))
    AND (
      m.host_user_id = sqlc.arg(requester_id)
      OR ST_DWithin(
        m.location,
        ST_SetSRID(ST_MakePoint(sqlc.arg(viewer_lng)::float8, sqlc.arg(viewer_lat)::float8), 4326)::geography,
        40000
      )
    )
  ORDER BY m.id, r.created_at DESC NULLS LAST
)
SELECT * FROM deduped
WHERE (created_at, id) < (sqlc.arg(cursor_created_at)::timestamptz, sqlc.arg(cursor_id)::uuid)
ORDER BY created_at DESC, id DESC
LIMIT sqlc.arg(page_limit);

-- name: ListMeetupsByHostFirstPage :many
-- Real cursor pagination (2026-08-31 round-3 hardening), replacing round
-- 2's flat LIMIT 200 — that fix closed the unbounded-memory risk but left
-- a hard completeness ceiling: a host past 200 meetups had no way to
-- reach the rest. Mirrors ListOpenMeetupsByIntentFirstPage's keyset shape
-- exactly (fetch limit+1 in Go, ORDER BY created_at DESC, id DESC for a
-- stable sort a plain created_at DESC alone doesn't guarantee when two
-- rows share a timestamp).
SELECT
  m.*,
  COALESCE(u.full_name, '') AS host_full_name,
  u.profile_photo_url AS host_profile_photo_url,
  COALESCE(u.trust_level, 0) AS host_trust_level,
  COALESCE(ratings.rating_average, 0)::numeric(3,2) AS host_rating_average,
  COALESCE(ratings.rating_count, 0)::int AS host_rating_count,
  (SELECT count(*) FROM meetup.meetup_requests r WHERE r.meetup_id = m.id AND r.status = 'accepted') AS accepted_count
FROM meetup.meetups m
LEFT JOIN meetup.user_display_cache u ON u.user_id = m.host_user_id
LEFT JOIN LATERAL (
  SELECT ROUND(AVG(score), 2) AS rating_average, count(*) AS rating_count
  FROM meetup.meetup_user_ratings mr WHERE mr.rated_user_id = m.host_user_id
) ratings ON true
WHERE m.host_user_id = $1
ORDER BY m.created_at DESC, m.id DESC
LIMIT $2;

-- name: ListMeetupsByHostAfterCursor :many
-- Keyset continuation of ListMeetupsByHostFirstPage — same
-- (created_at, id) < (cursor) shape as
-- ListOpenMeetupsByIntentAfterCursor.
SELECT
  m.*,
  COALESCE(u.full_name, '') AS host_full_name,
  u.profile_photo_url AS host_profile_photo_url,
  COALESCE(u.trust_level, 0) AS host_trust_level,
  COALESCE(ratings.rating_average, 0)::numeric(3,2) AS host_rating_average,
  COALESCE(ratings.rating_count, 0)::int AS host_rating_count,
  (SELECT count(*) FROM meetup.meetup_requests r WHERE r.meetup_id = m.id AND r.status = 'accepted') AS accepted_count
FROM meetup.meetups m
LEFT JOIN meetup.user_display_cache u ON u.user_id = m.host_user_id
LEFT JOIN LATERAL (
  SELECT ROUND(AVG(score), 2) AS rating_average, count(*) AS rating_count
  FROM meetup.meetup_user_ratings mr WHERE mr.rated_user_id = m.host_user_id
) ratings ON true
WHERE m.host_user_id = $1
  AND (m.created_at, m.id) < (sqlc.arg(cursor_created_at)::timestamptz, sqlc.arg(cursor_id)::uuid)
ORDER BY m.created_at DESC, m.id DESC
LIMIT $2;

-- name: ListMeetupsRequestedByUserFirstPage :many
-- One row per meetup, carrying the requester's *latest* request status for
-- it (a requester can have multiple historical rows for the same meetup —
-- e.g. rejected, then withdrawn, then a fresh pending one — the UNIQUE
-- constraint is per (meetup_id, requester_id, status), not per
-- (meetup_id, requester_id) alone).
--
-- Real cursor pagination (2026-08-31 round-3 hardening) — same fix and
-- reasoning as ListMeetupsByHostFirstPage above, applied to the
-- requested-meetups side of the same pre-existing completeness ceiling.
WITH latest_request AS (
  SELECT DISTINCT ON (meetup_id) *
  FROM meetup.meetup_requests
  WHERE meetup.meetup_requests.requester_id = $1
  ORDER BY meetup_id, created_at DESC
)
SELECT
  m.*,
  COALESCE(u.full_name, '') AS host_full_name,
  u.profile_photo_url AS host_profile_photo_url,
  COALESCE(u.trust_level, 0) AS host_trust_level,
  COALESCE(ratings.rating_average, 0)::numeric(3,2) AS host_rating_average,
  COALESCE(ratings.rating_count, 0)::int AS host_rating_count,
  (SELECT count(*) FROM meetup.meetup_requests r2 WHERE r2.meetup_id = m.id AND r2.status = 'accepted') AS accepted_count,
  lr.status AS my_request_status,
  lr.auto_rejected AS my_request_auto_rejected
FROM latest_request lr
JOIN meetup.meetups m ON m.id = lr.meetup_id
LEFT JOIN meetup.user_display_cache u ON u.user_id = m.host_user_id
LEFT JOIN LATERAL (
  SELECT ROUND(AVG(score), 2) AS rating_average, count(*) AS rating_count
  FROM meetup.meetup_user_ratings mr WHERE mr.rated_user_id = m.host_user_id
) ratings ON true
ORDER BY m.created_at DESC, m.id DESC
LIMIT $2;

-- name: ListMeetupsRequestedByUserAfterCursor :many
-- Keyset continuation of ListMeetupsRequestedByUserFirstPage.
WITH latest_request AS (
  SELECT DISTINCT ON (meetup_id) *
  FROM meetup.meetup_requests
  WHERE meetup.meetup_requests.requester_id = $1
  ORDER BY meetup_id, created_at DESC
)
SELECT
  m.*,
  COALESCE(u.full_name, '') AS host_full_name,
  u.profile_photo_url AS host_profile_photo_url,
  COALESCE(u.trust_level, 0) AS host_trust_level,
  COALESCE(ratings.rating_average, 0)::numeric(3,2) AS host_rating_average,
  COALESCE(ratings.rating_count, 0)::int AS host_rating_count,
  (SELECT count(*) FROM meetup.meetup_requests r2 WHERE r2.meetup_id = m.id AND r2.status = 'accepted') AS accepted_count,
  lr.status AS my_request_status,
  lr.auto_rejected AS my_request_auto_rejected
FROM latest_request lr
JOIN meetup.meetups m ON m.id = lr.meetup_id
LEFT JOIN meetup.user_display_cache u ON u.user_id = m.host_user_id
LEFT JOIN LATERAL (
  SELECT ROUND(AVG(score), 2) AS rating_average, count(*) AS rating_count
  FROM meetup.meetup_user_ratings mr WHERE mr.rated_user_id = m.host_user_id
) ratings ON true
WHERE (m.created_at, m.id) < (sqlc.arg(cursor_created_at)::timestamptz, sqlc.arg(cursor_id)::uuid)
ORDER BY m.created_at DESC, m.id DESC
LIMIT $2;

-- name: MarkMeetupFull :exec
UPDATE meetup.meetups SET status = 'full' WHERE id = $1;

-- name: CancelMeetup :one
-- reason is required (validated by the service layer, ADR-020 §3) —
-- accepted participants are notified and gain a new rating-eligibility
-- path against the host, both handled in the service layer after this
-- write commits. host_user_id scoping (Round 11, docs/00-project/
-- action-tracker.md § 4b-26) is defense-in-depth alongside the existing
-- Go-level ownership check in service.go's CancelMeetup — mirrors
-- CloseMeetup's own ownership clause exactly; the Go-level check stays,
-- this doesn't replace it.
UPDATE meetup.meetups SET status = 'cancelled', cancelled_at = now(), cancellation_reason = $2
WHERE id = $1 AND host_user_id = $3
RETURNING *;

-- name: CloseMeetup :one
-- The WHERE clause's four conditions (right meetup, right host, currently
-- open-ish, window actually started) are the *entire* authorization and
-- precondition check — done in the query itself so there's no window
-- between "check" and "act" for a concurrent request to slip through
-- (ADR-016). Zero rows updated (vs. an error) means one of those four
-- failed; the service layer re-fetches to distinguish which for a useful
-- error message.
UPDATE meetup.meetups
SET status = 'completed', closed_at = now()
WHERE id = $1 AND host_user_id = $2 AND status IN ('open', 'full') AND now() >= window_start
RETURNING *;

-- name: ClaimMeetupsStartingSoon :many
-- The lifecycle poller's starting-soon sweep (ADR-025 §4), reshaped into an
-- atomic CLAIM (docs/plans/03-hardening-pass.md §C2).
--
-- WHAT CHANGED AND WHY: this used to be a plain SELECT of candidates, with
-- the de-dup guard (starting_soon_notified_at) set afterwards, per row, once
-- the notification had been sent. That is correct for exactly one poller. It
-- is not correct for two — and horizontally scaling cmd/monolith for
-- throughput is a realistic near-term move. Two pollers ticking within the
-- same window would both SELECT the same rows before either wrote the guard,
-- and every host and participant would get the reminder twice.
--
-- Selecting and marking in ONE statement removes that window entirely: the
-- inner SELECT takes row locks with FOR UPDATE SKIP LOCKED, so a second
-- poller running concurrently skips the locked rows rather than waiting for
-- them and then re-processing, and the UPDATE stamps the guard before the
-- transaction that claimed them can be observed by anyone else. RETURNING
-- hands back exactly the rows this caller now owns.
--
-- The trade-off this makes deliberately: the guard is set BEFORE the
-- notification is composed rather than after, so a crash between claim and
-- notify loses that reminder. That is acceptable precisely because the
-- caller enqueues the notification into meetup.notification_outbox inside
-- THIS SAME TRANSACTION (§F3) — the claim and the queued notification commit
-- together, so there is no state where a meetup is marked notified but the
-- notification does not exist.
UPDATE meetup.meetups SET starting_soon_notified_at = now()
WHERE id IN (
  SELECT id FROM meetup.meetups
  WHERE status IN ('open', 'full')
    AND window_start - now() <= interval '30 minutes'
    AND window_start > now()
    AND starting_soon_notified_at IS NULL
  ORDER BY window_start
  LIMIT sqlc.arg(batch_size)
  FOR UPDATE SKIP LOCKED
)
RETURNING *;

-- name: ClaimMeetupsToAutoClose :many
-- The lifecycle poller's auto-close sweep (ADR-025 §4), same reshaping and
-- the same reasoning as ClaimMeetupsStartingSoon above (§C2).
--
-- The previous shape (SELECT candidates, then a per-row conditional UPDATE)
-- already prevented double-CLOSING — the UPDATE's own WHERE clause re-checked
-- eligibility, so a second closer simply affected zero rows. What it did NOT
-- prevent was duplicate NOTIFICATION: both pollers read the same candidate,
-- both then went on to notify the host and every participant, and only one
-- of them lost the race on the UPDATE it had already sent pushes for. Claiming
-- with FOR UPDATE SKIP LOCKED means the second poller never sees the row at
-- all.
--
-- status/window_end are still both re-checked here rather than trusted from
-- a prior read, so a concurrent manual CloseMeetup on the same row is
-- resolved by the database rather than by ordering assumptions.
UPDATE meetup.meetups
SET status = 'completed', closed_at = now()
WHERE id IN (
  SELECT id FROM meetup.meetups
  WHERE status IN ('open', 'full') AND now() >= window_end
  ORDER BY window_end
  LIMIT sqlc.arg(batch_size)
  FOR UPDATE SKIP LOCKED
)
RETURNING *;

-- name: RecomputeMeetupsCompletedForParticipants :many
-- Everyone whose "meetups completed" total is changed by the meetups in
-- meetup_ids having just completed, together with each one's NEW total.
--
-- Runs inside the same transaction that completed those meetups, so the
-- counts already include them — that is what lets the event carry an
-- absolute figure rather than a delta, and absolute is what makes the auth
-- module's consumer idempotent under redelivery (see auth/0005).
--
-- PARTICIPANT = the host, plus every requester whose request is 'accepted'.
-- Deliberately NOT gated on the Safety Gate check-in: check-in is a safety
-- affordance people can legitimately skip, and someone who attended but
-- never opened the checklist has still completed a meetup. The same
-- definition IsParticipant uses everywhere else in this module.
--
-- One statement rather than "list participants, then count per participant":
-- the fan-out is small (a meetup's capacity), but the 1+N version would run
-- inside the close transaction and hold it open for the round trips.
WITH participants AS (
    SELECT m.host_user_id AS user_id
      FROM meetup.meetups m
     WHERE m.id = ANY(sqlc.arg(meetup_ids)::uuid[])
    UNION
    SELECT r.requester_id AS user_id
      FROM meetup.meetup_requests r
     WHERE r.meetup_id = ANY(sqlc.arg(meetup_ids)::uuid[])
       AND r.status = 'accepted'
)
SELECT p.user_id,
       (
           SELECT count(*)
             FROM meetup.meetups done
            WHERE done.status = 'completed'
              AND (
                  done.host_user_id = p.user_id
                  OR EXISTS (
                      SELECT 1
                        FROM meetup.meetup_requests dr
                       WHERE dr.meetup_id = done.id
                         AND dr.requester_id = p.user_id
                         AND dr.status = 'accepted'
                  )
              )
       )::bigint AS meetups_completed
  FROM participants p;

-- name: ListMeetupParticipants :many
-- The people on a meetup: its host, plus everyone whose request was
-- accepted. Ordered host-first, then by name, so the list reads the same way
-- every time it is fetched.
--
-- Deliberately NOT scoped to a viewer. Who may see WHAT of this is a policy
-- question the service layer answers (see ListMeetupParticipants there) —
-- this query answers only "who is on this meetup". Mixing the two here would
-- put a trust rule in SQL where nobody reviewing the trust ladder would
-- think to look for it.
SELECT
  participants.user_id,
  participants.is_host,
  COALESCE(u.full_name, '') AS full_name,
  u.profile_photo_url,
  COALESCE(u.trust_level, 0) AS trust_level
FROM (
  SELECT m.host_user_id AS user_id, true AS is_host
  FROM meetup.meetups m WHERE m.id = sqlc.arg(meetup_id)
  UNION
  SELECT r.requester_id AS user_id, false AS is_host
  FROM meetup.meetup_requests r
  WHERE r.meetup_id = sqlc.arg(meetup_id) AND r.status = 'accepted'
) participants
LEFT JOIN meetup.user_display_cache u ON u.user_id = participants.user_id
ORDER BY participants.is_host DESC, u.full_name;
