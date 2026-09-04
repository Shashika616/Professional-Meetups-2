-- Minimal real SOS + trusted contacts (ADR-026, Slice H).

-- name: InsertTrustedContact :one
INSERT INTO auth.trusted_contacts (user_id, name, phone_number, email)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: ListTrustedContactsForUser :many
SELECT * FROM auth.trusted_contacts WHERE user_id = $1 ORDER BY created_at ASC;

-- name: CountTrustedContactsForUser :one
-- Backs the soft cap of 3 per user (ADR-026 §1), enforced at the service
-- layer, not a DB constraint.
SELECT count(*) FROM auth.trusted_contacts WHERE user_id = $1;

-- name: DeleteTrustedContact :execrows
-- Scoped to (id, user_id) so a caller can never delete another user's
-- contact by guessing an id — the service layer additionally checks
-- ownership explicitly first (same "no row for this caller -> Forbidden"
-- pattern ratings.go/safety.go already established) rather than relying on
-- this WHERE clause alone to produce the right error shape.
DELETE FROM auth.trusted_contacts WHERE id = $1 AND user_id = $2;

-- name: InsertSOSEvent :exec
INSERT INTO auth.sos_events (user_id, context_message, latitude, longitude, contacts_notified)
VALUES ($1, $2, $3, $4, $5);
