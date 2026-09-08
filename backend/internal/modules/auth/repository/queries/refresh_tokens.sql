-- name: CreateRefreshToken :one
INSERT INTO auth.refresh_tokens (user_id, token_hash, expires_at)
VALUES ($1, $2, $3)
RETURNING *;

-- name: GetRefreshTokenByHash :one
SELECT * FROM auth.refresh_tokens WHERE token_hash = $1;

-- name: GetRefreshTokenByID :one
SELECT * FROM auth.refresh_tokens WHERE id = $1;

-- name: MarkRefreshTokenReplaced :exec
UPDATE auth.refresh_tokens SET replaced_by = $2
WHERE id = $1;

-- name: RevokeRefreshTokenByHash :exec
UPDATE auth.refresh_tokens SET revoked_at = now()
WHERE token_hash = $1 AND revoked_at IS NULL;

-- name: RevokeAllRefreshTokensForUser :execrows
-- The reuse-detection response (docs/plans/03-hardening-pass.md §B1): when a
-- refresh token that has already been rotated or revoked is presented again,
-- every still-live token in that user's session family is revoked, not just
-- the replayed one. Rows affected tells the caller how many sessions were
-- actually terminated, purely for the security log line.
--
-- Deliberately unconditional on expiry: revoking an already-expired row is a
-- harmless no-op that keeps the WHERE clause (and therefore the index usage)
-- simple, and "revoked_at IS NULL" is the only condition that matters for
-- idempotency.
UPDATE auth.refresh_tokens SET revoked_at = now()
WHERE user_id = $1 AND revoked_at IS NULL;

-- name: DeleteExpiredRefreshTokens :execrows
-- The retention sweep (§B3). Every login and every refresh inserts a row and
-- nothing ever deleted one, so this table grew without bound — cheap to trim
-- continuously now, expensive to backfill-delete from a large table under
-- production load later.
--
-- Batched via the id subquery rather than one unbounded DELETE: on the first
-- run after this ships (or after the sweep has been disabled for a while)
-- the eligible set could be very large, and a single statement would hold
-- one long transaction and a correspondingly long lock. The caller loops
-- until this returns 0.
--
-- Two eligibility rules, both meaning "this row can never authenticate
-- anything again":
--   * revoked_at IS NOT NULL — explicitly killed (logout, rotation, or §B1's
--     family revocation).
--   * expires_at < now() - retention — expired, plus a grace window kept
--     deliberately so a recent expiry is still visible while debugging a
--     "why was I logged out" report.
DELETE FROM auth.refresh_tokens
WHERE id IN (
  SELECT id FROM auth.refresh_tokens
  WHERE revoked_at IS NOT NULL
     OR expires_at < sqlc.arg(expired_before)::timestamptz
  LIMIT sqlc.arg(batch_size)
);
