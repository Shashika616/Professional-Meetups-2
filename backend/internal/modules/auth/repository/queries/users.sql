-- name: GetUserByLinkedInSub :one
SELECT * FROM auth.users WHERE linkedin_sub = $1;

-- name: GetUserByID :one
SELECT * FROM auth.users WHERE id = $1;

-- name: GetUserByIDForUpdate :one
-- The read half of every trust-level write (gap-tracker #17). FOR UPDATE
-- holds a row lock for the rest of the enclosing transaction, so a
-- concurrent verification step for the same user either already committed
-- (and this read sees it) or blocks until this one commits (and so sees
-- this write). Without it both callers compute trust_level from the same
-- pre-write snapshot and the later write silently under-stamps it.
SELECT * FROM auth.users WHERE id = $1 FOR UPDATE;

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
--
-- is_guest is passed explicitly rather than left to the column DEFAULT: the
-- guest path is the only caller that sets it true, and making every caller
-- state which kind of account it is creating keeps a future fifth signup path
-- from silently inheriting "not a guest" without anyone deciding it.
INSERT INTO auth.users (linkedin_sub, full_name, profile_photo_url, headline, trust_level, age_confirmed_over_18, age_confirmed_at, is_guest)
VALUES ($1, $2, $3, $4, $5, $6, CASE WHEN $6 THEN now() ELSE NULL END, $7)
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
--
-- is_guest is cleared here too (ADR-002 §3): connecting LinkedIn is one of
-- the four real signup paths, so a guest doing it stops being a guest.
UPDATE auth.users SET linkedin_sub = $2, trust_level = $3, is_guest = false WHERE id = $1 RETURNING *;

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
--
-- EVERY ONE OF THEM ALSO CLEARS is_guest (ADR-002 §3). Completing any real
-- verification is exactly what stops an account being a guest, and putting
-- that in the SQL rather than at the call sites means it cannot be forgotten
-- by one of them — the failure it prevents is a guest who verifies something,
-- stays flagged, and is stranded at Level 0 with no way to notice why.
-- Idempotent: it is already false for every non-guest account.

-- name: UpdateUserPhoneNumber :one
UPDATE auth.users SET phone_number = $2, trust_level = $3, is_guest = false WHERE id = $1 RETURNING *;

-- name: UpdateUserPersonalEmail :one
UPDATE auth.users SET personal_email = $2, trust_level = $3, is_guest = false WHERE id = $1 RETURNING *;

-- name: UpdateUserPersonalDetails :one
UPDATE auth.users SET legal_name = $2, address = $3, trust_level = $4, is_guest = false WHERE id = $1 RETURNING *;

-- name: UpdateUserWorkEmailVerified :one
-- work_email_hash is set alongside company_domain/work_email_verified
-- (ADR-019 §3) — a keyed HMAC of the normalized raw address, the reuse-
-- abuse check's UNIQUE anchor (GetUserByWorkEmailHash below is what
-- detects a collision BEFORE this runs; the UNIQUE constraint here is the
-- last-resort race guard, same pattern as phone_number/personal_email).
--
-- company_name (ADR-002 §1) is written HERE, in the same statement as
-- work_email_verified, rather than through a separate save. That is the whole
-- reason no new RPC was added for it: Level 3 requires both a verified work
-- email AND a non-empty company name, and writing them together makes it
-- impossible for the row to hold one without the other. VerifyCorporateEmailCode
-- already required, validated and length-capped company_name long before this
-- change (it feeds the known-companies name-vs-domain cross-check) — it simply
-- had nowhere to be persisted.
UPDATE auth.users SET company_domain = $2, work_email_verified = $3, work_email_verified_at = $4, work_email_hash = $5, trust_level = $6, company_name = $7, is_guest = false
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

-- name: UpsertUserMeetupsCompletedCache :execrows
-- The meetups-completed consumer's idempotent, order-guarded upsert.
--
-- The event carries an ABSOLUTE count, not a delta. That is what makes a
-- redelivery safe: re-applying "this user has completed 7 meetups" is a
-- no-op, whereas re-applying "+1" would silently inflate the number every
-- time the bus redelivered.
--
-- Corrected 2026-09-08: this used to guard on `occurred_at` (mirroring
-- UpsertUserRatingCache above), the way every other guarded-upsert in this
-- codebase does. That comparison is wrong for THIS cache specifically —
-- unlike a rating average, a completed-meetup count is monotonically
-- non-decreasing per user (a meetup can never un-complete), so the value
-- itself is a safe, strictly correct ordering key, and comparing on it is
-- strictly safer than comparing on wall-clock time: two concurrent
-- completions for the same user (e.g. a manual host-close racing an
-- auto-close sweep's batch recompute) can each recompute from a snapshot
-- that doesn't see the other's not-yet-committed completion, so the
-- transaction that happens to commit second can carry a LOWER correct
-- count with a LATER timestamp — under the old guard that overwrites the
-- higher, correct value, and nothing ever corrects it since this cache is
-- only ever written from a completion event, never reconciled. Guarding on
-- the count itself makes a stale/lower recompute a no-op instead of a
-- regression, with no loss of redelivery-safety (an exact-equal redelivery
-- is still a no-op, just via `>` instead of failing an `IS NULL` check).
UPDATE auth.users
SET meetups_completed = sqlc.arg(meetups_completed),
    meetups_completed_updated_at = sqlc.arg(occurred_at)
WHERE id = sqlc.arg(user_id)
  AND sqlc.arg(meetups_completed)::int > meetups_completed;

-- name: ClearUserGuestFlag :one
-- Linking Apple or Google to an existing account (LinkIdentityToUser's
-- non-LinkedIn branch, ADR-002 §3). That path writes only user_identities,
-- so unlike every other verification it has no users UPDATE to ride along
-- with — hence its own statement.
--
-- It writes trust_level too, for the same reason every other mutation above
-- does: the caller has already computed the new value, and leaving it stale
-- would strand a freshly-upgraded guest at 0 until some unrelated write
-- happened to recompute it.
UPDATE auth.users SET is_guest = false, trust_level = $2 WHERE id = $1 RETURNING *;

-- name: DeleteAbandonedGuests :execrows
-- Guest-account cleanup (plan 14 Part B). A guest signs up, never verifies,
-- eventually signs out — and the row sits there forever with no way to reach
-- it again, since a guest account has no email, phone or LinkedIn to sign
-- back in with.
--
-- Three conditions, all required:
--   * is_guest = true — a HARD exclusion. is_guest only ever flips to false
--     (nothing sets it back), so a real account can never become eligible
--     here no matter how long it sits unused.
--   * no refresh_tokens row at all — an anti-join, not a stored "signed out"
--     flag. refresh_tokens is already the source of truth for "can this
--     account still authenticate"; a second derivable column would be free
--     to drift out of sync with it. Note this means ANY row blocks deletion,
--     including a dead one: the refresh-token sweep in the same tick removes
--     those first, so an account becomes eligible only once its last token
--     has been swept.
--   * updated_at older than the retention window — the same grace period the
--     refresh-token sweep uses, so a just-abandoned account stays
--     inspectable for the same length of time a just-expired token does.
--
-- Batched by id the same way DeleteExpiredRefreshTokens is, and for the same
-- reason: the caller loops until a batch comes back short, so no single
-- statement holds a long lock.
DELETE FROM auth.users
WHERE id IN (
  SELECT u.id FROM auth.users u
  WHERE u.is_guest = true
    AND u.updated_at < sqlc.arg(abandoned_before)::timestamptz
    AND NOT EXISTS (
      SELECT 1 FROM auth.refresh_tokens rt WHERE rt.user_id = u.id
    )
  LIMIT sqlc.arg(batch_size)
);
