-- name: UpsertMeetupFeedback :one
INSERT INTO meetup.meetup_feedback (meetup_id, user_id, happened, felt_safe, profile_accurate, would_meet_again, notes)
VALUES ($1, $2, $3, $4, $5, $6, $7)
ON CONFLICT (meetup_id, user_id) DO UPDATE SET
  happened = $3, felt_safe = $4, profile_accurate = $5, would_meet_again = $6, notes = $7, submitted_at = now()
RETURNING *;
