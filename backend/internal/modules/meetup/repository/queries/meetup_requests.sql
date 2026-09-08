-- name: CreateMeetupRequest :one
INSERT INTO meetup.meetup_requests (meetup_id, requester_id)
VALUES ($1, $2)
RETURNING *;

-- name: GetMeetupRequestByID :one
-- Plain, no join — used inside Accept's transaction where requester
-- display info is irrelevant, and as the base row write queries (Accept/
-- Reject/Withdraw) RETURNING against. Callers needing display info should
-- use GetMeetupRequestWithRequesterInfoByID instead.
SELECT * FROM meetup.meetup_requests WHERE id = $1;

-- name: GetMeetupRequestWithRequesterInfoByID :one
-- See meetup.meetups.sql's GetMeetupByID for why user_display_cache/
-- meetup_user_ratings are both LEFT JOINed (not JOIN) here.
SELECT
  r.*,
  COALESCE(u.full_name, '') AS requester_full_name,
  u.profile_photo_url AS requester_profile_photo_url,
  COALESCE(u.trust_level, 0) AS requester_trust_level,
  COALESCE(ratings.rating_average, 0)::numeric(3,2) AS requester_rating_average,
  COALESCE(ratings.rating_count, 0)::int AS requester_rating_count
FROM meetup.meetup_requests r
LEFT JOIN meetup.user_display_cache u ON u.user_id = r.requester_id
LEFT JOIN LATERAL (
  SELECT ROUND(AVG(score), 2) AS rating_average, count(*) AS rating_count
  FROM meetup.meetup_user_ratings mr WHERE mr.rated_user_id = r.requester_id
) ratings ON true
WHERE r.id = $1;

-- name: ListRequestsForMeetup :many
-- LEFT JOIN meetup.safety_state (ADR-024 §6) — host visibility into each
-- accepted participant's check-in status, piggybacking on this query's
-- existing host-only ListMeetupRequests call site rather than a new
-- endpoint. A pending/rejected/withdrawn request never has a safety-state
-- row (EnsureExists only ever runs at accept-time), so these columns are
-- naturally NULL for anything that isn't accepted — no extra WHERE needed.
-- One join, not a per-row follow-up query (avoids N+1).
SELECT
  r.*,
  COALESCE(u.full_name, '') AS requester_full_name,
  u.profile_photo_url AS requester_profile_photo_url,
  COALESCE(u.trust_level, 0) AS requester_trust_level,
  COALESCE(ratings.rating_average, 0)::numeric(3,2) AS requester_rating_average,
  COALESCE(ratings.rating_count, 0)::int AS requester_rating_count,
  safety.checked_in_at AS requester_checked_in_at,
  safety.declined_at AS requester_declined_at,
  safety.decline_reason AS requester_decline_reason
FROM meetup.meetup_requests r
LEFT JOIN meetup.user_display_cache u ON u.user_id = r.requester_id
LEFT JOIN LATERAL (
  SELECT ROUND(AVG(score), 2) AS rating_average, count(*) AS rating_count
  FROM meetup.meetup_user_ratings mr WHERE mr.rated_user_id = r.requester_id
) ratings ON true
LEFT JOIN meetup.safety_state safety
  ON safety.meetup_id = r.meetup_id AND safety.user_id = r.requester_id
WHERE r.meetup_id = $1
ORDER BY r.created_at ASC;

-- name: CountAcceptedRequests :one
SELECT count(*) FROM meetup.meetup_requests WHERE meetup_id = $1 AND status = 'accepted';

-- name: AcceptMeetupRequest :one
-- host_user_id scoping (Round 11, docs/00-project/action-tracker.md
-- § 4b-26) is defense-in-depth alongside the existing Go-level ownership
-- check in RespondToRequest/acceptRequest — meetup_requests has no
-- host_user_id column of its own, so this goes through a subquery against
-- meetups, the same relationship the Go check already enforces. The
-- Go-level check stays, this doesn't replace it.
UPDATE meetup.meetup_requests SET status = 'accepted', resolved_at = now()
WHERE meetup.meetup_requests.id = $1 AND meetup.meetup_requests.meetup_id IN (SELECT m.id FROM meetup.meetups m WHERE m.host_user_id = $2)
RETURNING *;

-- name: RejectMeetupRequest :one
-- WHERE status = 'pending' guards against rejecting an already-resolved
-- request (double-tap, or a race with auto-reject) — zero rows affected
-- (pgx.ErrNoRows) is the repository's signal to map to apperror.ErrConflict.
-- host_user_id scoping (Round 11) added the same way as AcceptMeetupRequest
-- above — defense-in-depth alongside the existing Go-level check.
UPDATE meetup.meetup_requests SET status = 'rejected', resolved_at = now()
WHERE meetup.meetup_requests.id = $1 AND meetup.meetup_requests.status = 'pending' AND meetup.meetup_requests.meetup_id IN (SELECT m.id FROM meetup.meetups m WHERE m.host_user_id = $2)
RETURNING *;

-- name: AutoRejectPendingRequestsForMeetup :many
-- Returns the rejected rows so the caller can notify each requester
-- (backend/meetup-scheduling-PLAN.md Step E).
UPDATE meetup.meetup_requests SET status = 'rejected', resolved_at = now(), auto_rejected = true
WHERE meetup_id = $1 AND status = 'pending'
RETURNING *;

-- name: WithdrawMeetupRequest :one
-- Both 'pending' and 'accepted' are withdrawable (ADR-020 §4) — widened
-- from the original pending-only precondition: a requester backing out
-- *after* being accepted is exactly the case the withdrawal-rating path
-- exists for ("the meetup continues for everyone else," ADR-020's own
-- framing — only meaningful if they'd actually been accepted into it).
-- note is optional (may be NULL). Does not touch the meetup's own
-- capacity/status — a freed-up slot on a full meetup reopening is a
-- separate, not-yet-built concern. requester_id scoping (Round 11,
-- docs/00-project/action-tracker.md § 4b-26) is defense-in-depth
-- alongside the existing Go-level check in service.go's WithdrawRequest —
-- scoped to the *requester*, not the host, unlike Accept/Reject/Cancel.
-- The Go-level check stays, this doesn't replace it.
UPDATE meetup.meetup_requests SET status = 'withdrawn', resolved_at = now(), withdrawal_note = $2
WHERE id = $1 AND requester_id = $3 AND status IN ('pending', 'accepted')
RETURNING *;
