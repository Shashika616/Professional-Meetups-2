-- name: GetActivePriceRules :one
SELECT * FROM billing.price_rules WHERE active;

-- name: GetActiveSubscription :one
-- A subscription counts while it is active inside its current period, or
-- in its grace period until the grace ends (Apple reports the grace end;
-- Google moves the period end itself).
SELECT s.user_id, s.plan_code, s.status, s.platform, s.current_period_start, s.current_period_end,
       p.meetups_included, p.max_capacity, p.max_advance_days, p.period AS plan_period
FROM billing.subscriptions s
JOIN billing.plans p ON p.code = s.plan_code
WHERE s.user_id = sqlc.arg(user_id)
  AND s.current_period_start <= sqlc.arg(now)::timestamptz
  AND (
      (s.status = 'active' AND s.current_period_end > sqlc.arg(now)::timestamptz)
      OR (s.status = 'grace_period'
          AND GREATEST(s.current_period_end, COALESCE(s.grace_period_end, s.current_period_end)) > sqlc.arg(now)::timestamptz)
  );

-- name: GetPlan :one
SELECT * FROM billing.plans WHERE code = sqlc.arg(code);

-- name: UpsertManualSubscription :exec
-- An operator's plan replaces any store subscription outright, store link
-- included, so a later store notification cannot overwrite it.
INSERT INTO billing.subscriptions (
    user_id, plan_code, status, platform, current_period_start, current_period_end, auto_renew, updated_at
) VALUES (
    sqlc.arg(user_id), sqlc.arg(plan_code), sqlc.arg(status), 'manual',
    sqlc.arg(period_start), sqlc.arg(period_end), false, now()
)
ON CONFLICT (user_id) DO UPDATE
SET plan_code = EXCLUDED.plan_code, status = EXCLUDED.status, platform = 'manual',
    current_period_start = EXCLUDED.current_period_start,
    current_period_end = EXCLUDED.current_period_end,
    auto_renew = false, original_transaction_id = NULL, product_id = NULL, grace_period_end = NULL,
    updated_at = now();

-- name: EnsurePlanUsage :exec
INSERT INTO billing.plan_usage (user_id, period_start) VALUES (sqlc.arg(user_id), sqlc.arg(period_start))
ON CONFLICT (user_id, period_start) DO NOTHING;

-- name: LockPlanUsage :one
SELECT * FROM billing.plan_usage
WHERE user_id = sqlc.arg(user_id) AND period_start = sqlc.arg(period_start)
FOR UPDATE;

-- name: GetPlanUsage :one
SELECT * FROM billing.plan_usage WHERE user_id = sqlc.arg(user_id) AND period_start = sqlc.arg(period_start);

-- name: SetPlanUsage :exec
UPDATE billing.plan_usage SET used = sqlc.arg(used), held = sqlc.arg(held)
WHERE user_id = sqlc.arg(user_id) AND period_start = sqlc.arg(period_start);

-- name: GetWelcomeGrant :one
SELECT * FROM billing.welcome_grants WHERE user_id = sqlc.arg(user_id);

-- name: InsertWelcomeGrant :execrows
-- No conflict target on purpose: a clash on EITHER unique column — this
-- account already granted, or this person already granted on another
-- account — makes it zero rows.
INSERT INTO billing.welcome_grants (user_id, identity_fingerprint, lot_id, amount)
VALUES (sqlc.arg(user_id), sqlc.arg(identity_fingerprint), sqlc.arg(lot_id), sqlc.arg(amount))
ON CONFLICT DO NOTHING;

-- name: InsertRefundLog :execrows
INSERT INTO billing.refund_log (user_id, hold_id, meetup_id, event, outcome, percent, amount)
VALUES (sqlc.arg(user_id), sqlc.arg(hold_id), sqlc.narg(meetup_id), sqlc.arg(event), sqlc.arg(outcome),
        sqlc.arg(percent), sqlc.arg(amount))
ON CONFLICT (hold_id) DO NOTHING;

-- name: RefundLogExists :one
SELECT EXISTS (SELECT 1 FROM billing.refund_log WHERE hold_id = sqlc.arg(hold_id));

-- name: CountRefundsSince :one
-- 'released' counts too: a cancellation that arrived before its capture
-- and so was never charged is a refund all the same (29A review fix 4).
SELECT count(*) FROM billing.refund_log
WHERE user_id = sqlc.arg(user_id) AND outcome IN ('refunded', 'released')
  AND created_at > sqlc.arg(since)::timestamptz;

-- name: InsertAdminAudit :exec
INSERT INTO billing.admin_audit (user_id, action, detail, operator, reason)
VALUES (sqlc.arg(user_id), sqlc.arg(action), sqlc.arg(detail), sqlc.arg(operator), sqlc.arg(reason));

-- name: SumOpenPurchasedCredits :one
SELECT COALESCE(sum(remaining), 0)::bigint FROM billing.credit_lots
WHERE user_id = sqlc.arg(user_id) AND kind = 'purchase' AND remaining > 0;
