-- name: GetUserByLinkedInSub :one
SELECT * FROM auth.users WHERE linkedin_sub = $1;

-- name: GetUserByID :one
SELECT * FROM auth.users WHERE id = $1;

-- name: GetUserByPersonalEmail :one
-- personal_email's mere presence already means "verified" in this schema
-- (same "presence IS the signal" convention as linkedin_sub/phone_number —
-- it's only ever written via UpdateUserPersonalEmail, which only runs
-- after a successful OTP check) — no separate boolean to check here.
-- Used by SignUpOrRecoverWithEmail (ADR-014 decision #3, passwordless as
-- of ADR-019 §1) to detect the recovery case: an email-OTP signup against
-- an address that's already someone's verified personal_email.
SELECT * FROM auth.users WHERE personal_email = $1;

-- name: CreateUser :one
-- age_confirmed_at is set to now() only when age_confirmed_over_18 is true
-- (the only case CreateUser is ever called with, in practice — the service
-- layer rejects false before reaching here) — never backdated, never set
-- for a false confirmation.
INSERT INTO auth.users (linkedin_sub, full_name, profile_photo_url, headline, trust_level, age_confirmed_over_18, age_confirmed_at)
VALUES ($1, $2, $3, $4, $5, $6, CASE WHEN $6 THEN now() ELSE NULL END)
RETURNING *;

-- name: UpdateUserLinkedInSub :one
-- The LinkedIn branch of LinkIdentityToUser (ADR-014) — links LinkedIn to
-- an already-authenticated Level 0+ account (Profile's "Connect LinkedIn").
-- Direct LinkedIn signup (CompleteLinkedInOnboarding, unchanged by this
-- slice) still creates accounts via CreateUser directly; this query is
-- only for the linking-to-an-existing-account path. The partial unique
-- index idx_users_linkedin_sub (migration 0001) is what actually rejects
-- linking a LinkedIn subject already claimed by a different user — the
-- caller (internal/service) maps that 23505 into apperror.ErrConflict,
-- same pattern as UpdateUserPhoneNumber/UpdateUserPersonalEmail below.
UPDATE auth.users SET linkedin_sub = $2, trust_level = $3 WHERE id = $1 RETURNING *;

-- name: UpdateUserFullName :one
-- ADR-019 §2's post-auth profile-completion screen — CompleteProfileSetup
-- is the only caller. fullName is always required there, unlike every
-- other field on this table.
UPDATE auth.users SET full_name = $2 WHERE id = $1 RETURNING *;

-- Level 2/3 verification (ADR-012, backend/PLAN.md's matching addendum).
-- Each mutation also writes trust_level in the same statement — the caller
-- (internal/service) computes the new value via computeTrustLevel before
-- calling these, so the row is never left with a stale trust_level between
-- the field write and a separate recompute step.

-- name: UpdateUserPhoneNumber :one
UPDATE auth.users SET phone_number = $2, trust_level = $3 WHERE id = $1 RETURNING *;

-- name: UpdateUserPersonalEmail :one
UPDATE auth.users SET personal_email = $2, trust_level = $3 WHERE id = $1 RETURNING *;

-- name: UpdateUserPersonalDetails :one
UPDATE auth.users SET legal_name = $2, address = $3, trust_level = $4 WHERE id = $1 RETURNING *;

-- name: UpdateUserWorkEmailVerified :one
-- work_email_hash is set alongside company_domain/work_email_verified
-- (ADR-019 §3) — a keyed HMAC of the normalized raw address, the reuse-
-- abuse check's UNIQUE anchor (GetUserByWorkEmailHash below is what
-- detects a collision BEFORE this runs; the UNIQUE constraint here is the
-- last-resort race guard, same pattern as phone_number/personal_email).
UPDATE auth.users SET company_domain = $2, work_email_verified = $3, work_email_verified_at = $4, work_email_hash = $5, trust_level = $6
WHERE id = $1 RETURNING *;

-- name: UpdateUserLastKnownLocation :one
-- 40km geo-visibility (ADR-021 §4) — the browse screen's on-demand
-- location read is the only call site for this; no trust-level bump, no
-- other side effect. Plain unconditional UPDATE, not order-guarded: unlike
-- the event-consumer upserts elsewhere, this is a direct RPC write from the
-- same user's own device in request order, not a redelivered/out-of-order
-- Pub/Sub message.
UPDATE auth.users SET last_location_lat = $2, last_location_lng = $3, last_location_updated_at = now()
WHERE id = $1 RETURNING *;

-- name: GetUserByWorkEmailHash :one
-- Reuse-abuse check (ADR-019 §3) — called before committing a corporate-
-- email verification to detect whether this exact mailbox already
-- verified a DIFFERENT account. Returns apperror.ErrNotFound (wrapped) if
-- no user has this hash yet.
SELECT * FROM auth.users WHERE work_email_hash = $1;

-- name: UpsertUserRatingCache :execrows
-- The rating-updated consumer's idempotent, order-guarded upsert (ADR-018
-- Decision 2, ADR-017's addendum Step 5b) — users.rating_average/
-- rating_count are a read-only cache of what services/meetup owns as of
-- this migration, written only from here. The WHERE clause is the
-- ordering guard: applies unconditionally the first time (rating_updated_at
-- still NULL from auth/0004's ALTER TABLE default), otherwise only if this
-- event is strictly newer than whatever's already stored — an
-- out-of-order redelivery of an older event is a no-op, not a regression.
-- Rows affected (0 or 1) tells the caller whether the guard actually
-- skipped a stale event, purely for logging.
UPDATE auth.users
SET rating_average = sqlc.arg(rating_average),
    rating_count = sqlc.arg(rating_count),
    rating_updated_at = sqlc.arg(occurred_at)
WHERE id = sqlc.arg(user_id)
  AND (rating_updated_at IS NULL OR sqlc.arg(occurred_at)::timestamptz > rating_updated_at);
