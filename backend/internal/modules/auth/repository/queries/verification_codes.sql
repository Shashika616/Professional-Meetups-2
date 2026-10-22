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

-- name: ClaimVerificationAttempt :one
-- V-1 (security review 2026-10-01): spend an attempt ATOMICALLY, before the
-- code is compared.
--
-- The old flow read the row, checked `attempts >= 5` in Go, compared, and
-- incremented only on a mismatch. Every concurrent guess read attempts = 0
-- before any increment landed, so the five-guess cap bounded nothing: a
-- hundred parallel requests got a hundred guesses at a six-digit code, and a
-- fresh code could be requested every sixty seconds. For email login that is
-- an unauthenticated takeover path against any account with a personal email.
--
-- `attempts < max_attempts` inside the UPDATE is what fixes it. Postgres
-- serialises concurrent UPDATEs of the same row, and each one re-evaluates
-- the predicate against the committed value, so exactly max_attempts of them
-- can ever succeed no matter how many arrive at once. The losers get zero
-- rows back and never reach the comparison at all.
--
-- `expires_at > now()` folds the expiry check into the same statement rather
-- than leaving it as a separate Go-side read that could pass and then go
-- stale. Zero rows therefore means one of: no such code, expired, or the cap
-- is already spent — the service distinguishes them with a follow-up read
-- purely to keep the three user-facing messages it has always had.
--
-- max_attempts is a parameter, not a literal 5, so otpMaxAttempts in Go stays
-- the only place the cap is written down.
UPDATE auth.verification_codes SET attempts = attempts + 1
WHERE user_id = $1
  AND purpose = $2
  AND attempts < sqlc.arg(max_attempts)::smallint
  AND expires_at > now()
RETURNING *;

-- name: ConsumeVerificationCode :one
-- The other half of V-1: delete the row AND report whether this caller was
-- the one that deleted it.
--
-- The old success path was an unconditional DELETE whose result nobody
-- looked at, so two concurrent requests holding the same correct code both
-- "succeeded" and both got a session. Matching on code_hash and returning
-- the row makes the delete the point at which the code is spent: the first
-- caller gets a row, every later one gets zero and is told the code is
-- invalid, which by then it is.
DELETE FROM auth.verification_codes
WHERE user_id = $1 AND purpose = $2 AND code_hash = $3
RETURNING *;

-- Email-OTP signup (ADR-014 decision #2, migration 0004; passwordless as
-- of ADR-019 §1) — the account may not exist yet at OTP-send time (see
-- SignUpOrRecoverWithEmail's recovery path), so these four mirror the
-- four above exactly except keyed by (purpose, target) instead of
-- (user_id, purpose), via idx_verification_codes_signup_target. Used for
-- both VERIFICATION_PURPOSE_EMAIL_SIGNUP and VERIFICATION_PURPOSE_EMAIL_LOGIN
-- (migration 0006, ADR-019 §1) — user_id is always NULL on these rows.

-- name: UpsertVerificationCodeForSignup :one
-- ON CONFLICT infers target_normalized, not target (tracker #82).
--
-- The service normalises before it calls, so for every row this writes
-- the two columns hold the same string. The difference is what happens
-- when they do NOT: a call site that forgets to normalise, or a second
-- spelling arriving from somewhere new, must land on the SAME row rather
-- than inserting a second one with its own attempt counter and its own
-- cooldown. Conflicting on the normalised column is what makes "one
-- target, one budget" a property of the table instead of a convention
-- every caller has to remember.
--
-- target_normalized is GENERATED ALWAYS (migration 0020), so it cannot
-- be written directly and cannot drift from target.
INSERT INTO auth.verification_codes (user_id, purpose, target, code_hash, expires_at)
VALUES (NULL, $1, $2, $3, $4)
ON CONFLICT (purpose, target_normalized) WHERE user_id IS NULL
DO UPDATE SET target = $2, code_hash = $3, attempts = 0, expires_at = $4, created_at = now()
RETURNING *;

-- name: GetVerificationCodeByTarget :one
SELECT * FROM auth.verification_codes WHERE user_id IS NULL AND purpose = $1 AND target = $2;

-- name: IncrementVerificationAttemptsByTarget :one
UPDATE auth.verification_codes SET attempts = attempts + 1
WHERE user_id IS NULL AND purpose = $1 AND target = $2
RETURNING *;

-- name: DeleteVerificationCodeByTarget :exec
DELETE FROM auth.verification_codes WHERE user_id IS NULL AND purpose = $1 AND target = $2;

-- name: ClaimVerificationAttemptByTarget :one
-- The target-keyed twin of ClaimVerificationAttempt — same reasoning, and
-- the one that matters most: these purposes (email signup, email login,
-- account_claim) are UNAUTHENTICATED, so this is the cap an attacker meets
-- before they have any credential at all.
UPDATE auth.verification_codes SET attempts = attempts + 1
WHERE user_id IS NULL
  AND purpose = $1
  AND target = $2
  AND attempts < sqlc.arg(max_attempts)::smallint
  AND expires_at > now()
RETURNING *;

-- name: ConsumeVerificationCodeByTarget :one
-- The target-keyed twin of ConsumeVerificationCode.
DELETE FROM auth.verification_codes
WHERE user_id IS NULL AND purpose = $1 AND target = $2 AND code_hash = $3
RETURNING *;
