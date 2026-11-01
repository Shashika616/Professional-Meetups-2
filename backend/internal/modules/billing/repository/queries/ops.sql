-- The billing outbox (same claiming strategy as meetup.meetups_completed_
-- outbox: an UPDATE that stamps a visibility timeout) and the daily
-- reconciliation.

-- name: ClaimBillingOutboxBatch :many
UPDATE billing.billing_outbox
SET attempts = attempts + 1,
    next_attempt_at = now() + sqlc.arg(visibility_timeout)::interval
WHERE id IN (
  SELECT id FROM billing.billing_outbox
  WHERE processed_at IS NULL AND dead_lettered_at IS NULL AND next_attempt_at <= now()
  ORDER BY next_attempt_at
  LIMIT sqlc.arg(batch_size)
  FOR UPDATE SKIP LOCKED
)
RETURNING id, topic, payload, attempts;

-- name: MarkBillingOutboxProcessed :exec
UPDATE billing.billing_outbox SET processed_at = now(), last_error = NULL WHERE id = sqlc.arg(id);

-- name: MarkBillingOutboxFailed :exec
UPDATE billing.billing_outbox
SET next_attempt_at = sqlc.arg(next_attempt_at)::timestamptz, last_error = sqlc.arg(last_error)
WHERE id = sqlc.arg(id);

-- name: MarkBillingOutboxDeadLettered :exec
UPDATE billing.billing_outbox SET dead_lettered_at = now(), last_error = sqlc.arg(last_error)
WHERE id = sqlc.arg(id);

-- name: CountPendingBillingOutbox :one
SELECT count(*) FROM billing.billing_outbox WHERE processed_at IS NULL AND dead_lettered_at IS NULL;

-- name: DeleteProcessedBillingOutbox :execrows
DELETE FROM billing.billing_outbox
WHERE id IN (
  SELECT id FROM billing.billing_outbox
  WHERE processed_at IS NOT NULL AND processed_at < sqlc.arg(older_than)::timestamptz
  LIMIT sqlc.arg(batch_size)
);

-- name: DeleteDeadLetteredBillingOutbox :execrows
DELETE FROM billing.billing_outbox
WHERE id IN (
  SELECT id FROM billing.billing_outbox
  WHERE dead_lettered_at IS NOT NULL AND dead_lettered_at < sqlc.arg(older_than)::timestamptz
  LIMIT sqlc.arg(batch_size)
);

-- name: ReconcileWallets :many
-- Every wallet whose stored figures disagree with its lots, its open holds
-- or its own ledger replayed (plan 3.2). One pass over each table; at this
-- size that is cheaper than per-user round trips.
WITH lots AS (
  SELECT user_id, sum(remaining) AS remaining FROM billing.credit_lots GROUP BY user_id
), holds AS (
  SELECT user_id, sum(amount) AS held FROM billing.holds
  WHERE state = 'held' AND kind = 'credits' GROUP BY user_id
), ledger AS (
  SELECT user_id, sum(delta) AS delta, sum(held_delta) AS held_delta, sum(debt_delta) AS debt_delta
  FROM billing.ledger_entries GROUP BY user_id
)
SELECT w.user_id, w.balance, w.held, w.debt,
       COALESCE(lots.remaining, 0)::bigint AS lots_remaining,
       COALESCE(holds.held, 0)::bigint AS holds_held,
       COALESCE(ledger.delta, 0)::bigint AS ledger_balance,
       COALESCE(ledger.held_delta, 0)::bigint AS ledger_held,
       COALESCE(ledger.debt_delta, 0)::bigint AS ledger_debt
FROM billing.wallets w
LEFT JOIN lots ON lots.user_id = w.user_id
LEFT JOIN holds ON holds.user_id = w.user_id
LEFT JOIN ledger ON ledger.user_id = w.user_id
WHERE w.balance <> COALESCE(lots.remaining, 0)
   OR w.held <> COALESCE(holds.held, 0)
   OR w.balance <> COALESCE(ledger.delta, 0)
   OR w.held <> COALESCE(ledger.held_delta, 0)
   OR w.debt <> COALESCE(ledger.debt_delta, 0)
ORDER BY w.user_id;

-- name: CountWallets :one
SELECT count(*) FROM billing.wallets;

-- name: ReconciliationRunExists :one
SELECT EXISTS (SELECT 1 FROM billing.reconciliation_runs WHERE run_date = sqlc.arg(run_date));

-- name: InsertReconciliationRun :execrows
INSERT INTO billing.reconciliation_runs (run_date, checked, mismatches, detail)
VALUES (sqlc.arg(run_date), sqlc.arg(checked), sqlc.arg(mismatches), sqlc.arg(detail))
ON CONFLICT (run_date) DO NOTHING;

-- name: GetReconciliationRun :many
-- The daily report's read (29F): counts only.
SELECT checked, mismatches FROM billing.reconciliation_runs WHERE run_date = sqlc.arg(run_date);
