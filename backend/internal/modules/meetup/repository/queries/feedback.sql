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
-- happened is written explicitly: true for a meetup that took place —
-- reaching the end of the review flow IS the statement that it happened,
-- and null would make the row fail HasConfirmedMeetupHappened and refuse
-- the very ratings submitted alongside it — and false for a CANCELLED one,
-- whose review rates the host for cancelling, not an evening that occurred.
INSERT INTO meetup.meetup_feedback (meetup_id, user_id, happened, overall_score, notes, review_completed_at)
VALUES ($1, $2, sqlc.arg(happened), $3, $4, now())
ON CONFLICT (meetup_id, user_id) DO UPDATE SET
  happened = sqlc.arg(happened),
  overall_score = $3,
  notes = COALESCE($4, meetup.meetup_feedback.notes),
  review_completed_at = now(),
  submitted_at = now()
RETURNING *;

-- name: GetMeetupFeedback :one
SELECT * FROM meetup.meetup_feedback WHERE meetup_id = $1 AND user_id = $2;

-- name: ListMeetupIDsAwaitingReview :many
-- Meetups this user still owes a review on, bounded by a cutoff so an
-- ignored review does not sit on Home forever (see service.reviewWindow).
--
-- Two ways a meetup gets here:
--   1. It happened: the window has ended, and the user was its host or an
--      accepted participant.
--   2. It was CANCELLED by the host while this user held an accepted
--      request. The participant gave up an evening on the host's word and
--      gets to say how that went (ADR-020 §3's cancellation rating, now
--      reached through the ordinary review flow). The host is never asked
--      to review their own cancellation. Bounded by cancelled_at rather
--      than window_end, since a meetup can be cancelled long before it
--      would have started.
SELECT m.id
FROM meetup.meetups m
LEFT JOIN meetup.meetup_feedback f ON f.meetup_id = m.id AND f.user_id = sqlc.arg(user_id)
WHERE f.review_completed_at IS NULL
  AND (
    (
      m.status <> 'cancelled'
      AND m.window_end <= now()
      AND m.window_end > sqlc.arg(cutoff)
      AND (
        m.host_user_id = sqlc.arg(user_id)
        OR EXISTS (
          SELECT 1 FROM meetup.meetup_requests r
          WHERE r.meetup_id = m.id AND r.requester_id = sqlc.arg(user_id) AND r.status = 'accepted'
        )
      )
    )
    OR (
      m.status = 'cancelled'
      AND m.cancelled_at > sqlc.arg(cutoff)
      AND m.host_user_id <> sqlc.arg(user_id)
      AND EXISTS (
        SELECT 1 FROM meetup.meetup_requests r
        WHERE r.meetup_id = m.id AND r.requester_id = sqlc.arg(user_id) AND r.status = 'accepted'
      )
    )
  );