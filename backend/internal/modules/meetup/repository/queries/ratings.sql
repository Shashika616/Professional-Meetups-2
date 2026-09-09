-- name: IsMeetupParticipant :one
-- True if userID is the host of meetupID, or has an accepted request on it
-- — the "ratable set" (ADR-015, docs/02-domain/domain-model.md § Rating).
SELECT EXISTS(
  SELECT 1 FROM meetup.meetups m WHERE m.id = sqlc.arg(meetup_id) AND m.host_user_id = sqlc.arg(user_id)
  UNION
  SELECT 1 FROM meetup.meetup_requests r WHERE r.meetup_id = sqlc.arg(meetup_id) AND r.requester_id = sqlc.arg(user_id) AND r.status = 'accepted'
);

-- name: HasConfirmedMeetupHappened :one
-- The rating-eligibility gate: the *rater* must have already confirmed
-- (SubmitMeetupFeedback, happened=true) that the meetup happened. The ratee
-- does not need this — a no-show is legitimately ratable by someone who did
-- attend and confirm (ADR-015).
SELECT EXISTS(
  SELECT 1 FROM meetup.meetup_feedback WHERE meetup_id = $1 AND user_id = $2 AND happened = true
);

-- name: ListRatableParticipants :many
-- Host + accepted requesters of meetupID, excluding viewerID, each flagged
-- with whether viewerID has already rated them for this meetup. Also
-- includes (ADR-020 §3/§4):
--   - The host is already covered for the cancellation-triggered case
--     without any change here — this base query never filtered on
--     meetup.meetups.status, so an accepted requester on a now-cancelled meetup
--     already sees the host as ratable (meetup.meetup_requests.status stays
--     'accepted' through a cancellation — it's a meetup-level change, not
--     a per-request one). Verified explicitly by
--     TestListRatableParticipants_IncludesCancelledMeetupHost, not just
--     assumed from reading this comment.
--   - Withdrawn requesters, ratable only by the host — a genuinely new
--     source (the base query's second branch only ever selected
--     status = 'accepted'), gated to viewer_id = host_user_id directly in
--     this branch since a non-host viewer must never see a withdrawn
--     requester as ratable.
--
-- LEFT JOIN meetup.user_display_cache, not JOIN users (ADR-017's addendum — users
-- is a different database now; see meetup.meetups.sql's GetMeetupByID for the
-- full LEFT-JOIN-not-JOIN reasoning, same here) — a participant excluded
-- from this list because their display cache hasn't synced yet would be a
-- real (if narrow) correctness bug: someone ratable would silently not
-- appear to rate.
SELECT
  participants.user_id,
  COALESCE(u.full_name, '') AS full_name,
  u.profile_photo_url,
  COALESCE(u.trust_level, 0) AS trust_level,
  (mr.id IS NOT NULL)::boolean AS already_rated,
  participants.context_note
FROM (
  SELECT m.host_user_id AS user_id, NULL::text AS context_note
  FROM meetup.meetups m WHERE m.id = sqlc.arg(meetup_id)
  UNION
  SELECT r.requester_id AS user_id, NULL::text AS context_note
  FROM meetup.meetup_requests r WHERE r.meetup_id = sqlc.arg(meetup_id) AND r.status = 'accepted'
  UNION
  SELECT r.requester_id AS user_id, r.withdrawal_note AS context_note
  FROM meetup.meetup_requests r
  JOIN meetup.meetups m ON m.id = r.meetup_id
  WHERE r.meetup_id = sqlc.arg(meetup_id) AND r.status = 'withdrawn' AND m.host_user_id = sqlc.arg(viewer_id)
) participants
LEFT JOIN meetup.user_display_cache u ON u.user_id = participants.user_id
LEFT JOIN meetup.meetup_user_ratings mr
  ON mr.meetup_id = sqlc.arg(meetup_id) AND mr.rater_user_id = sqlc.arg(viewer_id) AND mr.rated_user_id = participants.user_id
WHERE participants.user_id <> sqlc.arg(viewer_id);

-- name: IsEligibleForCancellationRating :one
-- True if meetupID is cancelled, ratedID is that meetup's host, and
-- raterID has an accepted meetup_requests row for it (ADR-020 §3) — a
-- cancelled meetup's accepted requests stay 'accepted' (cancellation is a
-- meetup-level status change, not a per-request one), so this is a plain
-- status check, no separate "was accepted at cancellation time" column
-- needed.
SELECT EXISTS(
  SELECT 1 FROM meetup.meetups m
  WHERE m.id = sqlc.arg(meetup_id) AND m.status = 'cancelled' AND m.host_user_id = sqlc.arg(rated_id)
    AND EXISTS(
      SELECT 1 FROM meetup.meetup_requests r
      WHERE r.meetup_id = sqlc.arg(meetup_id) AND r.requester_id = sqlc.arg(rater_id) AND r.status = 'accepted'
    )
);

-- name: IsEligibleForWithdrawalRating :one
-- True if there's a meetup_requests row for meetupID with
-- status = 'withdrawn', requester_id = ratedID, and raterID is that
-- meetup's host — independent of the meetup's own status (ADR-020 §4:
-- "the meetup continues for everyone else," this is per-request, not
-- per-meetup).
SELECT EXISTS(
  SELECT 1 FROM meetup.meetup_requests r
  JOIN meetup.meetups m ON m.id = r.meetup_id
  WHERE r.meetup_id = sqlc.arg(meetup_id) AND r.requester_id = sqlc.arg(rated_id)
    AND r.status = 'withdrawn' AND m.host_user_id = sqlc.arg(rater_id)
);

-- name: CreateMeetupRating :one
INSERT INTO meetup.meetup_user_ratings (meetup_id, rater_user_id, rated_user_id, score, traits)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: ListMyMeetupRatings :many
-- What the viewer themselves submitted on this meetup — the read behind
-- "see the ratings we gave" on a history card. Only ever the viewer's own
-- rows (rater_user_id = viewer): a rating is private to the person who gave
-- it, and this must never become a way to read what others scored someone.
SELECT
  r.rated_user_id,
  COALESCE(u.full_name, '') AS full_name,
  u.profile_photo_url,
  r.score,
  r.traits
FROM meetup.meetup_user_ratings r
LEFT JOIN meetup.user_display_cache u ON u.user_id = r.rated_user_id
WHERE r.meetup_id = sqlc.arg(meetup_id) AND r.rater_user_id = sqlc.arg(viewer_id)
ORDER BY u.full_name;

-- name: ComputeUserRatingAggregate :one
-- Replaces the old RecomputeUserRating UPDATE (which wrote users.
-- rating_average/rating_count directly — the exact cross-database write
-- ADR-017 flagged, only possible before the DB split because this service
-- shared auth's database). This service no longer has a users table to
-- write to at all; the aggregate is computed here (read-only, over this
-- service's own meetup_user_ratings) purely to build the rating-updated
-- outbox event payload (Step 5b) — auth's own consumer applies it to its
-- cached columns on the other side. Run inside the same transaction as
-- CreateMeetupRating, after it, same as before — the row lock nothing
-- takes anymore (there's no users row to lock in this database), so
-- correctness for concurrent raters of the same person now rests on
-- meetup_user_ratings' own UNIQUE(meetup_id, rater_user_id, rated_user_id)
-- constraint plus each recompute reading committed rows only, not on a
-- row-lock serialization point the old design incidentally had.
SELECT
  COUNT(*)::int AS rating_count,
  COALESCE(ROUND(AVG(score), 2), 0)::numeric(3,2) AS rating_average
FROM meetup.meetup_user_ratings
WHERE rated_user_id = $1;
