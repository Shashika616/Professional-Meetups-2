-- name: UpsertVerificationCode :one
-- One pending code per (user_id, purpose) — a resend overwrites the
-- existing row (including resetting attempts and created_at) rather than
-- stacking a second one.
INSERT INTO auth.verification_codes (user_id, purpose, target, code_hash, expires_at)
VALUES ($1, $2, $3, $4, $5)
ON CONFLICT (user_id, purpose)
DO UPDATE SET target = $3, code_hash = $4, attempts = 0, expires_at = $5, created_at = now()
RETURNING *;

-- name: GetVerificationCode :one
SELECT * FROM auth.verification_codes WHERE user_id = $1 AND purpose = $2;

-- name: IncrementVerificationAttempts :one
UPDATE auth.verification_codes SET attempts = attempts + 1
WHERE user_id = $1 AND purpose = $2
RETURNING *;

-- name: DeleteVerificationCode :exec
DELETE FROM auth.verification_codes WHERE user_id = $1 AND purpose = $2;

-- Email-OTP signup (ADR-014 decision #2, migration 0004; passwordless as
-- of ADR-019 §1) — the account may not exist yet at OTP-send time (see
-- SignUpOrRecoverWithEmail's recovery path), so these four mirror the
-- four above exactly except keyed by (purpose, target) instead of
-- (user_id, purpose), via idx_verification_codes_signup_target. Used for
-- both VERIFICATION_PURPOSE_EMAIL_SIGNUP and VERIFICATION_PURPOSE_EMAIL_LOGIN
-- (migration 0006, ADR-019 §1) — user_id is always NULL on these rows.

-- name: UpsertVerificationCodeForSignup :one
INSERT INTO auth.verification_codes (user_id, purpose, target, code_hash, expires_at)
VALUES (NULL, $1, $2, $3, $4)
ON CONFLICT (purpose, target) WHERE user_id IS NULL
DO UPDATE SET code_hash = $3, attempts = 0, expires_at = $4, created_at = now()
RETURNING *;

-- name: GetVerificationCodeByTarget :one
SELECT * FROM auth.verification_codes WHERE user_id IS NULL AND purpose = $1 AND target = $2;

-- name: IncrementVerificationAttemptsByTarget :one
UPDATE auth.verification_codes SET attempts = attempts + 1
WHERE user_id IS NULL AND purpose = $1 AND target = $2
RETURNING *;

-- name: DeleteVerificationCodeByTarget :exec
DELETE FROM auth.verification_codes WHERE user_id IS NULL AND purpose = $1 AND target = $2;
