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

-- name: DeleteTrustedContactsForUser :exec
-- Account deletion. Not reached by the ON DELETE CASCADE from auth.users:
-- trusted_contacts.user_id is a logical FK with no constraint, by design
-- (0001_auth_schema's header). Without this the rows would outlive the
-- account — and they are the most sensitive thing in the schema, because
-- they are OTHER PEOPLE's names, phone numbers and email addresses, entered
-- by someone who has now asked to be forgotten.
DELETE FROM auth.trusted_contacts WHERE user_id = $1;

-- name: DeleteSOSEventsForUser :exec
-- Account deletion; same logical-FK reason as above. An SOS event records
-- where the user was when they asked for help.
DELETE FROM auth.sos_events WHERE user_id = $1;

-- name: CreateSafetyHoldForDeletedUser :execrows
-- Account deletion, inside the delete's own transaction and BEFORE the SOS
-- events are deleted. Copies the minimal identity and the SOS events into a
-- safety hold that purges itself at purge_after (see 0016_safety_holds).
--
-- The inner JOIN is the rule "only where there is a reason": an account with
-- no SOS events produces no row at all, and zero rows is the normal result.
INSERT INTO auth.safety_holds
  (deleted_user_id, full_name, legal_name, phone_number, personal_email, sos_events, purge_after)
SELECT
  u.id, u.full_name, u.legal_name, u.phone_number, u.personal_email,
  jsonb_agg(jsonb_build_object(
    'context_message',   s.context_message,
    'latitude',          s.latitude,
    'longitude',         s.longitude,
    'triggered_at',      s.triggered_at,
    'contacts_notified', s.contacts_notified
  ) ORDER BY s.triggered_at),
  now() + sqlc.arg(hold_for)::interval
FROM auth.users u
JOIN auth.sos_events s ON s.user_id = u.id
WHERE u.id = sqlc.arg(user_id)
GROUP BY u.id;

-- name: DeleteExpiredSafetyHolds :execrows
-- The sweeper, batched like the refresh-token sweep so no single statement
-- holds a long lock.
DELETE FROM auth.safety_holds
WHERE id IN (
  SELECT id FROM auth.safety_holds
  WHERE purge_after < now()
  LIMIT sqlc.arg(batch_size)
);
