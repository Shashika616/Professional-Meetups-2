-- name: CreateRefreshToken :one
INSERT INTO auth.refresh_tokens (user_id, token_hash, expires_at)
VALUES ($1, $2, $3)
RETURNING *;

-- name: GetRefreshTokenByHash :one
SELECT * FROM auth.refresh_tokens WHERE token_hash = $1;

-- name: GetRefreshTokenByID :one
SELECT * FROM auth.refresh_tokens WHERE id = $1;

-- name: MarkRefreshTokenReplaced :one
-- The claim that makes rotation single-use (tracker #83, review finding
-- N-A2 / #57).
--
-- # WHAT THE MISSING GUARD COST
--
-- This was `WHERE id = $1` and nothing else, with the "is this token
-- still live?" check done earlier, in Go, on a row read outside the
-- transaction. Two refreshes presenting the SAME token concurrently both
-- passed that check, both inserted a child, and both marked the parent
-- replaced: one parent, two live children, two session chains descended
-- from one token. Reuse detection keys on replaced_by being set, so
-- neither chain ever looks stolen — the fork is permanent and invisible.
--
-- The three conditions are the whole check, moved to where it can be
-- trusted: the row's own UPDATE. A second transaction blocks on this
-- row's lock, then re-evaluates against the committed version and
-- matches nothing, so it gets zero rows instead of a second child.
--
-- expires_at > now() is here as well as in Go for the same reason — the
-- Go check reads a snapshot, this one reads the row being written.
--
-- :one, so zero rows surfaces as pgx.ErrNoRows rather than a silent
-- success. The caller turns that into reuse, which revokes the family.
UPDATE auth.refresh_tokens SET replaced_by = $2
WHERE id = $1
  AND replaced_by IS NULL
  AND revoked_at IS NULL
  AND expires_at > now()
RETURNING *;

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
--
-- ONLY rows nothing still points at. `replaced_by` is a self-reference
-- (0001_auth_schema) with no ON DELETE action, and rotation links each row
-- to the one that replaced it: old.replaced_by = new.id. So the NEWER row
-- in a chain is the referenced one, and deleting an arbitrary LIMIT-sized
-- batch hit `violates foreign key constraint
-- "refresh_tokens_replaced_by_fkey"` whenever a batch contained a row whose
-- referrer was not also in it. In production this meant the sweep failed on
-- every run and the table never shrank at all.
--
-- Restricting the batch to unreferenced rows deletes each chain from its
-- OLDEST end, which is the only order the constraint permits. One pass
-- removes one layer; the caller loops until a pass deletes nothing, so a
-- whole chain still goes in a single sweep. A chain whose newest token is
-- still live keeps that token and loses the dead ones behind it, which is
-- exactly right.
--
-- ON DELETE SET NULL on the constraint would also "work" and is the wrong
-- fix: `replaced_by IS NULL` is how MarkRefreshTokenReplaced detects that a
-- token has not yet been rotated, so nulling it on an arbitrary delete
-- would make a rotated token look fresh to the reuse check.
DELETE FROM auth.refresh_tokens
WHERE id IN (
  SELECT t.id FROM auth.refresh_tokens t
  WHERE (t.revoked_at IS NOT NULL
      OR t.expires_at < sqlc.arg(expired_before)::timestamptz)
    AND NOT EXISTS (
      SELECT 1 FROM auth.refresh_tokens r WHERE r.replaced_by = t.id
    )
  LIMIT sqlc.arg(batch_size)
);
