-- Queries behind another member's public profile (GET /v1/users/{id}).
-- Who may open a profile depends on what viewer and target have shared; see
-- member.go in the service layer. What a profile then shows does not depend
-- on the viewer at all (plan 2.3).

-- name: CanViewMemberProfile :one
-- True when the viewer may open the target's profile: they are the same
-- person; the target hosts (or has hosted) a meetup — a host is public by
-- design, since you must be able to judge them before asking to join; the
-- viewer HOSTS a meetup the target asked to join (see below); or the two
-- were both on one meetup as host/accepted. "Shared" deliberately counts
-- past meetups: once you have sat at a table with someone, their profile
-- stays open to you.
--
-- # WHY A HOST SEES EVERY REQUESTER, INCLUDING PENDING ONES
--
-- The host has to decide whether to let this person sit down with them.
-- A name, a photo and a level badge is not enough to decide on, which is
-- exactly why the request card in the app opens this profile. Withholding
-- it until after the host accepts inverts the decision: it would mean
-- accepting someone in order to find out who they are.
--
-- Deliberately ONE-DIRECTIONAL. This clause only ever opens the requester
-- to the host, never the other way round and never requester to requester:
-- a pending requester still cannot see who else is on the meetup (that is
-- ListMeetupParticipants' redaction, and it stays until they are accepted).
-- The reverse direction needs no clause anyway — a host is already public
-- to everyone by the rule above.
--
-- Status-agnostic on purpose. A withdrawn or turned-down requester stays
-- visible to that host: they approached the host, the host already saw
-- them in the request list, and the host may still have to rate them for
-- withdrawing (ADR-020 §4). Re-hiding a profile the host could already
-- read would only break the rating screen.
SELECT
  sqlc.arg(viewer_id)::uuid = sqlc.arg(target_id)::uuid
  OR EXISTS (
    SELECT 1 FROM meetup.meetups m WHERE m.host_user_id = sqlc.arg(target_id)::uuid
  )
  OR EXISTS (
    SELECT 1
    FROM meetup.meetup_requests r
    JOIN meetup.meetups m ON m.id = r.meetup_id
    WHERE r.requester_id = sqlc.arg(target_id)::uuid
      AND m.host_user_id = sqlc.arg(viewer_id)::uuid
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
-- The meetups the target HOSTED that are over, newest first, with what the
-- profile shows of each (plan 2.3). Only the host's are listed: a member who
-- joined shows a count and a rating, never where they were.
--
-- Only meetups that are over (#103): completed, or past their window and not
-- yet swept. An open or full meetup is a future time and place, and a
-- profile is not where those are published.
--
-- The average is the participants' opinion of the meetup: the host's own
-- review of it is left out.
SELECT
  m.intent,
  m.status,
  m.window_start,
  m.location_label,
  (1 + (SELECT count(*) FROM meetup.meetup_requests r WHERE r.meetup_id = m.id AND r.status = 'accepted'))::int AS participant_count,
  COALESCE((SELECT avg(f.overall_score) FROM meetup.meetup_feedback f WHERE f.meetup_id = m.id AND f.user_id <> m.host_user_id AND f.overall_score IS NOT NULL), 0)::float8 AS overall_average,
  (SELECT count(*) FROM meetup.meetup_feedback f WHERE f.meetup_id = m.id AND f.user_id <> m.host_user_id AND f.overall_score IS NOT NULL)::int AS review_count
FROM meetup.meetups m
WHERE m.host_user_id = sqlc.arg(target_id)::uuid
  AND (m.status = 'completed' OR (m.status IN ('open', 'full') AND m.window_end < now()))
ORDER BY m.window_start DESC
LIMIT sqlc.arg(page_limit);

-- name: ListHostReviews :many
-- The written reviews participants left on the target's hosted meetups,
-- newest first (plan 2.3). Always anonymous: this query cannot name anyone,
-- because no author column and no meetup column leave it. A review is not
-- tied to a meetup on the profile either, since a small meetup's guest list
-- would then give the author away.
SELECT
  f.overall_score::int AS score,
  f.notes,
  f.review_completed_at
FROM meetup.meetup_feedback f
JOIN meetup.meetups m ON m.id = f.meetup_id
WHERE m.host_user_id = sqlc.arg(target_id)::uuid
  AND f.user_id <> m.host_user_id
  -- Only a finished review is public (#90). A row can exist, and carry
  -- text, before its author ever completed the review.
  AND f.review_completed_at IS NOT NULL
  AND f.overall_score IS NOT NULL
  AND f.notes IS NOT NULL AND btrim(f.notes) <> ''
ORDER BY f.review_completed_at DESC
LIMIT sqlc.arg(page_limit);
