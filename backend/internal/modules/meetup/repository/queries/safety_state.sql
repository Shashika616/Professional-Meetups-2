-- name: EnsureSafetyState :exec
-- Idempotent create-if-missing — called once per participant, at meetup
-- creation for the host and at accept-time for each accepted requester
-- (ADR-024 §2). ON CONFLICT DO NOTHING rather than upsert-with-RETURNING
-- since callers always follow this with a plain Get.
INSERT INTO meetup.safety_state (meetup_id, user_id) VALUES ($1, $2)
ON CONFLICT (meetup_id, user_id) DO NOTHING;

-- name: GetSafetyState :one
SELECT * FROM meetup.safety_state WHERE meetup_id = $1 AND user_id = $2;

-- name: SetChecklistAck :one
UPDATE meetup.safety_state SET checklist_ack_at = now()
WHERE meetup_id = $1 AND user_id = $2
RETURNING *;

-- name: SetLiveLocationOptIn :one
UPDATE meetup.safety_state SET live_location_opt_in = $3
WHERE meetup_id = $1 AND user_id = $2
RETURNING *;

-- name: SetCheckedIn :one
UPDATE meetup.safety_state SET checked_in_at = now()
WHERE meetup_id = $1 AND user_id = $2
RETURNING *;

-- name: SetDeclined :one
-- ADR-024 §4 — mutual exclusion with check-in is enforced at the service
-- layer (both states are visible together there), not here.
UPDATE meetup.safety_state SET declined_at = now(), decline_reason = $3
WHERE meetup_id = $1 AND user_id = $2
RETURNING *;

-- name: RecordSafetyShare :exec
-- Records that contact_id was told about this meetup by user_id.
--
-- ON CONFLICT DO NOTHING keeps the FIRST notified_at. Re-sharing with a
-- contact who already knows is a no-op rather than a second row (and, at the
-- service layer above, a second text message) — the primary key is what
-- makes "select all" safe to press twice.
INSERT INTO meetup.safety_share (meetup_id, user_id, contact_id)
VALUES (sqlc.arg(meetup_id), sqlc.arg(user_id), sqlc.arg(contact_id))
ON CONFLICT (meetup_id, user_id, contact_id) DO NOTHING;

-- name: ListSafetyShareContactIDs :many
-- Everyone this user has already told about this meetup, so the screen can
-- show it instead of asking again blind.
SELECT contact_id
  FROM meetup.safety_share
 WHERE meetup_id = sqlc.arg(meetup_id)
   AND user_id = sqlc.arg(user_id)
 ORDER BY notified_at;
