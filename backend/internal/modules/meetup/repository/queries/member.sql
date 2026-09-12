-- Queries behind another member's public profile (GET /v1/users/{id}).
-- Every one takes the VIEWER as well as the target, because what is
-- visible depends on what the two of them have shared — see
-- member.go in the service layer for the rule.

-- name: CanViewMemberProfile :one
-- True when the viewer may open the target's profile: they are the same
-- person; the target hosts (or has hosted) a meetup — a host is public by
-- design, since you must be able to judge them before asking to join; or
-- the two were both on one meetup as host/accepted. "Shared" deliberately
-- counts past meetups: once you have sat at a table with someone, their
-- profile stays open to you.
SELECT
  sqlc.arg(viewer_id)::uuid = sqlc.arg(target_id)::uuid
  OR EXISTS (
    SELECT 1 FROM meetup.meetups m WHERE m.host_user_id = sqlc.arg(target_id)::uuid
  )
  OR EXISTS (
    SELECT 1
    FROM (
      SELECT m.id AS meetup_id, m.host_user_id AS user_id FROM meetup.meetups m
      UNION ALL
      SELECT r.meetup_id, r.requester_id FROM meetup.meetup_requests r WHERE r.status = 'accepted'
    ) a
    JOIN (
      SELECT m.id AS meetup_id, m.host_user_id AS user_id FROM meetup.meetups m
      UNION ALL
      SELECT r.meetup_id, r.requester_id FROM meetup.meetup_requests r WHERE r.status = 'accepted'
    ) b ON b.meetup_id = a.meetup_id
    WHERE a.user_id = sqlc.arg(viewer_id)::uuid AND b.user_id = sqlc.arg(target_id)::uuid
  ) AS can_view;

-- name: ListRecentMeetupsForMember :many
-- The target's last N meetups as host or accepted participant, newest
-- window first, with the aggregate the profile shows per meetup and whether
-- the VIEWER was on it too (which decides whether reviewer names below are
-- shown or withheld).
WITH membership AS (
  SELECT m.id AS meetup_id, m.host_user_id AS user_id, true AS is_host FROM meetup.meetups m
  UNION ALL
  SELECT r.meetup_id, r.requester_id, false FROM meetup.meetup_requests r WHERE r.status = 'accepted'
)
SELECT
  m.id,
  m.intent,
  m.status,
  m.window_start,
  m.window_end,
  m.location_label,
  tm.is_host AS target_is_host,
  (SELECT count(*) FROM membership c WHERE c.meetup_id = m.id)::int AS participant_count,
  COALESCE((SELECT avg(f.overall_score) FROM meetup.meetup_feedback f WHERE f.meetup_id = m.id AND f.overall_score IS NOT NULL), 0)::float8 AS overall_average,
  (SELECT count(*) FROM meetup.meetup_feedback f WHERE f.meetup_id = m.id AND f.overall_score IS NOT NULL)::int AS review_count,
  EXISTS (SELECT 1 FROM membership v WHERE v.meetup_id = m.id AND v.user_id = sqlc.arg(viewer_id)::uuid) AS viewer_was_in
FROM meetup.meetups m
JOIN membership tm ON tm.meetup_id = m.id AND tm.user_id = sqlc.arg(target_id)::uuid
WHERE m.status <> 'cancelled'
ORDER BY m.window_start DESC
LIMIT sqlc.arg(page_limit);

-- name: ListMeetupReviewComments :many
-- The written comments on a set of meetups, oldest first within a meetup.
-- The author's display name rides along; the service blanks it for a
-- viewer who was not on that meetup.
SELECT
  f.meetup_id,
  f.user_id AS author_id,
  COALESCE(u.full_name, '') AS author_name,
  f.notes,
  f.review_completed_at
FROM meetup.meetup_feedback f
LEFT JOIN meetup.user_display_cache u ON u.user_id = f.user_id
WHERE f.meetup_id = ANY(sqlc.arg(meetup_ids)::uuid[])
  AND f.notes IS NOT NULL AND btrim(f.notes) <> ''
ORDER BY f.meetup_id, f.review_completed_at;
