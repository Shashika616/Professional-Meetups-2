-- name: GetStoreProduct :one
SELECT * FROM billing.store_products WHERE product_id = sqlc.arg(product_id) AND active;

-- name: ListCatalogProducts :many
-- Every active product, with its plan's catalog text for subscriptions.
SELECT sp.product_id, sp.kind, sp.credits, sp.bonus, sp.plan_code, sp.period, sp.badge, sp.sort, sp.featured,
       COALESCE(p.title, '')::text AS plan_title, COALESCE(p.perks, '[]'::jsonb) AS plan_perks
FROM billing.store_products sp
LEFT JOIN billing.plans p ON p.code = sp.plan_code
WHERE sp.active AND (sp.plan_code IS NULL OR p.active)
ORDER BY sp.sort, sp.product_id;

-- name: InsertStorePurchase :one
-- A repeated transaction inserts nothing and returns no row; the caller
-- then reads the original.
INSERT INTO billing.store_purchases (
    user_id, platform, transaction_id, original_transaction_id, token_hash, product_id, kind,
    app_account_token, environment, raw, pending_finish_token
) VALUES (
    sqlc.arg(user_id), sqlc.arg(platform), sqlc.arg(transaction_id), sqlc.arg(original_transaction_id),
    sqlc.narg(token_hash), sqlc.arg(product_id), sqlc.arg(kind), sqlc.arg(app_account_token),
    sqlc.arg(environment), sqlc.arg(raw), sqlc.narg(pending_finish_token)
)
ON CONFLICT (platform, transaction_id) DO NOTHING
RETURNING *;

-- name: GetStorePurchase :one
SELECT * FROM billing.store_purchases WHERE platform = sqlc.arg(platform) AND transaction_id = sqlc.arg(transaction_id);

-- name: GetStorePurchaseByID :one
SELECT * FROM billing.store_purchases WHERE id = sqlc.arg(id);

-- name: LockStorePurchase :one
SELECT * FROM billing.store_purchases WHERE id = sqlc.arg(id) FOR UPDATE;

-- name: FindStorePurchaseByTokenHash :one
SELECT * FROM billing.store_purchases
WHERE platform = sqlc.arg(platform) AND token_hash = sqlc.arg(token_hash)
ORDER BY verified_at DESC LIMIT 1;

-- name: FindStorePurchaseByOriginal :one
-- The account a store subscription (or its renewals) belongs to.
SELECT * FROM billing.store_purchases
WHERE platform = sqlc.arg(platform) AND original_transaction_id = sqlc.arg(original_transaction_id)
ORDER BY verified_at ASC LIMIT 1;

-- name: SetStorePurchaseGrant :exec
UPDATE billing.store_purchases SET credits = sqlc.arg(credits), lot_id = sqlc.arg(lot_id) WHERE id = sqlc.arg(id);

-- name: MarkStorePurchaseFinished :exec
UPDATE billing.store_purchases SET finished_at = now(), pending_finish_token = NULL WHERE id = sqlc.arg(id);

-- name: MarkStorePurchaseRefunded :execrows
UPDATE billing.store_purchases SET refunded_at = now(), pending_finish_token = NULL
WHERE id = sqlc.arg(id) AND refunded_at IS NULL;

-- name: InsertProcessedNotification :execrows
-- Zero rows means this notification was handled before.
INSERT INTO billing.processed_store_notifications (platform, notification_id, notification_type, subtype, outcome)
VALUES (sqlc.arg(platform), sqlc.arg(notification_id), sqlc.arg(notification_type), sqlc.narg(subtype), sqlc.arg(outcome))
ON CONFLICT (platform, notification_id) DO NOTHING;

-- name: CountProcessedNotifications :one
SELECT count(*) FROM billing.processed_store_notifications
WHERE platform = sqlc.arg(platform) AND notification_id = sqlc.arg(notification_id);

-- name: LockSubscription :one
SELECT * FROM billing.subscriptions WHERE user_id = sqlc.arg(user_id) FOR UPDATE;

-- name: GetSubscriptionByOriginal :one
SELECT * FROM billing.subscriptions
WHERE platform = sqlc.arg(platform) AND original_transaction_id = sqlc.arg(original_transaction_id);

-- name: UpsertStoreSubscription :exec
INSERT INTO billing.subscriptions (
    user_id, plan_code, status, platform, original_transaction_id, product_id,
    current_period_start, current_period_end, grace_period_end, auto_renew, updated_at
) VALUES (
    sqlc.arg(user_id), sqlc.arg(plan_code), sqlc.arg(status), sqlc.arg(platform),
    sqlc.arg(original_transaction_id), sqlc.arg(product_id), sqlc.arg(period_start), sqlc.arg(period_end),
    sqlc.narg(grace_period_end), sqlc.arg(auto_renew), now()
)
ON CONFLICT (user_id) DO UPDATE
SET plan_code = EXCLUDED.plan_code, status = EXCLUDED.status, platform = EXCLUDED.platform,
    original_transaction_id = EXCLUDED.original_transaction_id, product_id = EXCLUDED.product_id,
    current_period_start = EXCLUDED.current_period_start, current_period_end = EXCLUDED.current_period_end,
    grace_period_end = EXCLUDED.grace_period_end, auto_renew = EXCLUDED.auto_renew, updated_at = now();

-- name: GetSubscriptionView :one
-- The caller's subscription in any status, for GET /v1/billing/subscription.
SELECT s.user_id, s.plan_code, s.status, s.platform, s.product_id, s.current_period_start, s.current_period_end,
       s.grace_period_end, s.auto_renew, p.meetups_included, p.max_capacity, p.max_advance_days
FROM billing.subscriptions s
JOIN billing.plans p ON p.code = s.plan_code
WHERE s.user_id = sqlc.arg(user_id);

-- name: GetLot :one
SELECT * FROM billing.credit_lots WHERE id = sqlc.arg(id) FOR UPDATE;

-- name: ExpireLotNow :exec
-- A refunded purchase's lot: credits a meetup refund later returns to it
-- expire at once instead of reviving the refunded purchase.
UPDATE billing.credit_lots SET expires_at = sqlc.arg(now) WHERE id = sqlc.arg(id);
