-- name: UpsertMeetupFeedback :one
INSERT INTO meetup.meetup_feedback (meetup_id, user_id, happened, felt_safe, profile_accurate, would_meet_again, notes)
VALUES ($1, $2, $3, $4, $5, $6, $7)
ON CONFLICT (meetup_id, user_id) DO UPDATE SET
  happened = $3, felt_safe = $4, profile_accurate = $5, would_meet_again = $6, notes = $7, submitted_at = now()
RETURNING *;

-- name: SetMeetupOverallReview :one
-- The review flow's own write: the overall 1-5 for the meetup plus the
-- optional note, and the completion stamp. Separate from
-- UpsertMeetupFeedback (the safety questions) because the two are answered
-- at different moments by different screens, and a review must never
-- silently clear a felt_safe answer given earlier.
--
-- happened is forced true: reaching the end of the review flow IS the
-- statement that it happened, and leaving it null would make the row fail
-- HasConfirmedMeetupHappened and so refuse the very ratings being submitted
-- alongside it.
INSERT INTO meetup.meetup_feedback (meetup_id, user_id, happened, overall_score, notes, review_completed_at)
VALUES ($1, $2, true, $3, $4, now())
ON CONFLICT (meetup_id, user_id) DO UPDATE SET
  happened = true,
  overall_score = $3,
  notes = COALESCE($4, meetup.meetup_feedback.notes),
  review_completed_at = now(),
  submitted_at = now()
RETURNING *;

-- name: GetMeetupFeedback :one
SELECT * FROM meetup.meetup_feedback WHERE meetup_id = $1 AND user_id = $2;

-- name: ListMeetupIDsAwaitingReview :many
-- Meetups this user took part in whose window has ended and which they have
-- not finished reviewing. Bounded by a cutoff so an ignored review does not
-- sit on Home forever (see service.reviewWindow).
SELECT m.id
FROM meetup.meetups m
LEFT JOIN meetup.meetup_feedback f ON f.meetup_id = m.id AND f.user_id = sqlc.arg(user_id)
WHERE m.window_end <= now()
  AND m.window_end > sqlc.arg(cutoff)
  AND m.status <> 'cancelled'
  AND f.review_completed_at IS NULL
  AND (
    m.host_user_id = sqlc.arg(user_id)
    OR EXISTS (
      SELECT 1 FROM meetup.meetup_requests r
      WHERE r.meetup_id = m.id AND r.requester_id = sqlc.arg(user_id) AND r.status = 'accepted'
    )
  );
