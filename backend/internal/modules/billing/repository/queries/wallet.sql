-- The ledger core's statements. Every write path in internal/modules/billing/
-- wallet takes the wallet row FOR UPDATE first (LockWallet) and touches lots,
-- holds and the ledger only after it, so one user's operations serialise on
-- that one row and lock order is always wallet -> lots -> holds.

-- name: EnsureWallet :exec
INSERT INTO billing.wallets (user_id) VALUES (sqlc.arg(user_id)) ON CONFLICT (user_id) DO NOTHING;

-- name: LockWallet :one
SELECT * FROM billing.wallets WHERE user_id = sqlc.arg(user_id) FOR UPDATE;

-- name: LockWalletNoWait :one
-- For sweeps: a wallet some request is writing right now is skipped, not
-- waited for. That request applies the same due decay itself.
SELECT * FROM billing.wallets WHERE user_id = sqlc.arg(user_id) FOR UPDATE SKIP LOCKED;

-- name: GetWallet :one
SELECT * FROM billing.wallets WHERE user_id = sqlc.arg(user_id);

-- name: UpdateWallet :exec
UPDATE billing.wallets
SET balance = sqlc.arg(balance), held = sqlc.arg(held), debt = sqlc.arg(debt),
    version = version + 1, updated_at = now()
WHERE user_id = sqlc.arg(user_id);

-- name: CloseWallet :execrows
UPDATE billing.wallets SET closed_at = now(), updated_at = now()
WHERE user_id = sqlc.arg(user_id) AND closed_at IS NULL;

-- name: InsertLot :one
INSERT INTO billing.credit_lots (
    user_id, kind, initial, remaining, granted_at, expires_at,
    decay_percent, decay_every, next_decay_at, source_ref
) VALUES (
    sqlc.arg(user_id), sqlc.arg(kind), sqlc.arg(initial), sqlc.arg(initial), sqlc.arg(granted_at),
    sqlc.narg(expires_at), sqlc.narg(decay_percent), sqlc.narg(decay_every),
    sqlc.narg(next_decay_at), sqlc.narg(source_ref)
)
RETURNING *;

-- name: LockDueLots :many
-- Lots with a decay period or an expiry that has come due. A decaying lot
-- that is already empty is still returned so its schedule advances and it
-- stops coming due.
SELECT * FROM billing.credit_lots
WHERE user_id = sqlc.arg(user_id)
  AND ((next_decay_at IS NOT NULL AND next_decay_at <= sqlc.arg(now)::timestamptz)
       OR (expires_at IS NOT NULL AND expires_at <= sqlc.arg(now)::timestamptz AND remaining > 0))
ORDER BY granted_at, id
FOR UPDATE;

-- name: LockSpendableLots :many
-- The spend order (plan 3.2): earliest expiry first, purchased credits
-- (NULL expiry) last. Called in small batches until the amount is covered,
-- so a capture touches only the lots it uses; a lot it empties drops out of
-- the next batch.
SELECT * FROM billing.credit_lots
WHERE user_id = sqlc.arg(user_id)
  AND remaining > 0
  AND (expires_at IS NULL OR expires_at > sqlc.arg(now)::timestamptz)
ORDER BY expires_at NULLS LAST, granted_at, id
LIMIT sqlc.arg(batch_size)
FOR UPDATE;

-- name: LockLotsByID :many
SELECT * FROM billing.credit_lots
WHERE id = ANY(sqlc.arg(ids)::uuid[]) AND user_id = sqlc.arg(user_id)
ORDER BY id
FOR UPDATE;

-- name: SetLotRemaining :exec
UPDATE billing.credit_lots SET remaining = sqlc.arg(remaining) WHERE id = sqlc.arg(id);

-- name: SetLotDecay :exec
UPDATE billing.credit_lots
SET remaining = sqlc.arg(remaining),
    decay_periods_applied = sqlc.arg(decay_periods_applied),
    next_decay_at = sqlc.narg(next_decay_at)
WHERE id = sqlc.arg(id);

-- name: ListOpenLots :many
SELECT * FROM billing.credit_lots
WHERE user_id = sqlc.arg(user_id) AND remaining > 0
ORDER BY expires_at NULLS LAST, granted_at, id;

-- name: UsersWithDueLots :many
SELECT DISTINCT user_id FROM billing.credit_lots
WHERE (next_decay_at IS NOT NULL AND next_decay_at <= sqlc.arg(now)::timestamptz)
   OR (expires_at IS NOT NULL AND expires_at <= sqlc.arg(now)::timestamptz AND remaining > 0)
LIMIT sqlc.arg(batch_size);

-- name: InsertHold :one
INSERT INTO billing.holds (
    user_id, kind, amount, price_version, period_start, expires_at, idempotency_key
) VALUES (
    sqlc.arg(user_id), sqlc.arg(kind), sqlc.arg(amount), sqlc.arg(price_version),
    sqlc.narg(period_start), sqlc.arg(expires_at), sqlc.arg(idempotency_key)
)
RETURNING *;

-- name: GetHoldByKey :one
SELECT * FROM billing.holds WHERE user_id = sqlc.arg(user_id) AND idempotency_key = sqlc.arg(idempotency_key);

-- name: SupersedeHoldKey :exec
-- Frees an idempotency key held by a released hold, so a retry of the same
-- request can reserve afresh under it. The old hold keeps its row (and its
-- ledger entries) under a key that can never collide.
UPDATE billing.holds SET idempotency_key = idempotency_key || ':superseded:' || id::text
WHERE id = sqlc.arg(id) AND state = 'released';

-- name: GetHold :one
SELECT * FROM billing.holds WHERE id = sqlc.arg(id);

-- name: LockHold :one
SELECT * FROM billing.holds WHERE id = sqlc.arg(id) AND user_id = sqlc.arg(user_id) FOR UPDATE;

-- name: MarkHoldCaptured :exec
UPDATE billing.holds
SET state = 'captured', captured_at = sqlc.arg(at)::timestamptz, meetup_id = sqlc.narg(meetup_id)
WHERE id = sqlc.arg(id);

-- name: MarkHoldReleased :exec
UPDATE billing.holds
SET state = 'released', released_at = sqlc.arg(at)::timestamptz, release_reason = sqlc.arg(reason)
WHERE id = sqlc.arg(id);

-- name: ExpiredHolds :many
SELECT id, user_id FROM billing.holds
WHERE state = 'held' AND expires_at <= sqlc.arg(now)::timestamptz
ORDER BY expires_at
LIMIT sqlc.arg(batch_size);

-- name: InsertAllocation :exec
INSERT INTO billing.hold_allocations (hold_id, lot_id, amount)
VALUES (sqlc.arg(hold_id), sqlc.arg(lot_id), sqlc.arg(amount))
ON CONFLICT (hold_id, lot_id) DO UPDATE SET amount = billing.hold_allocations.amount + EXCLUDED.amount;

-- name: LockAllocations :many
-- Refunds go back to the longest-lived lot first (purchased, then latest
-- expiry), which is the order that loses the user the least.
SELECT a.hold_id, a.lot_id, a.amount, a.refunded, l.expires_at
FROM billing.hold_allocations a
JOIN billing.credit_lots l ON l.id = a.lot_id
WHERE a.hold_id = sqlc.arg(hold_id)
ORDER BY l.expires_at DESC NULLS FIRST, l.granted_at DESC, a.lot_id
FOR UPDATE OF a;

-- name: AddAllocationRefund :exec
UPDATE billing.hold_allocations SET refunded = refunded + sqlc.arg(amount)
WHERE hold_id = sqlc.arg(hold_id) AND lot_id = sqlc.arg(lot_id);

-- name: InsertLedgerEntry :execrows
-- ON CONFLICT DO NOTHING turns a replayed operation into zero rows, which
-- the caller treats as "already applied" rather than a second write.
INSERT INTO billing.ledger_entries (
    user_id, delta, held_delta, debt_delta, reason, lot_id, hold_id, ref_type, ref_id,
    balance_after, held_after, debt_after, idempotency_key, operator, note
) VALUES (
    sqlc.arg(user_id), sqlc.arg(delta), sqlc.arg(held_delta), sqlc.arg(debt_delta), sqlc.arg(reason),
    sqlc.narg(lot_id), sqlc.narg(hold_id), sqlc.narg(ref_type), sqlc.narg(ref_id),
    sqlc.arg(balance_after), sqlc.arg(held_after), sqlc.arg(debt_after), sqlc.arg(idempotency_key),
    sqlc.narg(operator), sqlc.narg(note)
)
ON CONFLICT (user_id, idempotency_key) DO NOTHING;

-- name: LedgerKeyExists :one
SELECT EXISTS (
    SELECT 1 FROM billing.ledger_entries
    WHERE user_id = sqlc.arg(user_id) AND idempotency_key = sqlc.arg(idempotency_key)
);

-- name: LedgerDebtForKey :one
-- The debt one keyed entry recorded, 0 when there is no such entry.
SELECT COALESCE(sum(debt_delta), 0)::bigint FROM billing.ledger_entries
WHERE user_id = sqlc.arg(user_id) AND idempotency_key = sqlc.arg(idempotency_key);

-- name: ListLedger :many
-- Keyset pagination, newest first. before_id 0 means the first page.
SELECT * FROM billing.ledger_entries
WHERE user_id = sqlc.arg(user_id)
  AND (sqlc.arg(before_id)::bigint = 0 OR id < sqlc.arg(before_id)::bigint)
ORDER BY id DESC
LIMIT sqlc.arg(page_size);

-- name: InsertBillingOutbox :exec
INSERT INTO billing.billing_outbox (topic, payload) VALUES (sqlc.arg(topic), sqlc.arg(payload));
