-- Plan 29B: store purchases, subscriptions and the catalog (plan 29 §3.1,
-- §3.7, §3.8). Every table is in the billing schema; user ids are plain
-- UUIDs, as in 0026 (ADR-001 §3).

-- What the stores sell, and what each product is worth here. The catalog
-- (GET /v1/billing/catalog) is built from this table and never carries a
-- price: the app shows the store's localised price for these product ids.
-- One row per product id, the same id on both stores.
CREATE TABLE IF NOT EXISTS billing.store_products (
    product_id TEXT PRIMARY KEY CHECK (product_id ~ '^[a-z0-9_.]{1,100}$'),
    kind       TEXT NOT NULL CHECK (kind IN ('consumable', 'subscription')),
    -- Consumables: the credits granted per purchase, and the part of them
    -- shown as a bonus. The grant is credits + bonus.
    credits    BIGINT,
    bonus      BIGINT NOT NULL DEFAULT 0,
    -- Subscriptions: the plan it buys and its billing period.
    plan_code  TEXT REFERENCES billing.plans (code),
    period     TEXT CHECK (period IN ('month', 'year')),
    badge      TEXT,
    sort       INT NOT NULL DEFAULT 0,
    featured   BOOLEAN NOT NULL DEFAULT false,
    active     BOOLEAN NOT NULL DEFAULT true,
    CONSTRAINT store_products_shape CHECK (
        (kind = 'consumable' AND credits > 0 AND bonus >= 0 AND plan_code IS NULL AND period IS NULL)
        OR (kind = 'subscription' AND credits IS NULL AND bonus = 0 AND plan_code IS NOT NULL AND period IS NOT NULL)
    )
);

-- D6 and D5. credits_120 is 100 + 20 bonus; credits_300 is 225 + 75.
INSERT INTO billing.store_products (product_id, kind, credits, bonus, plan_code, period, badge, sort, featured) VALUES
    ('credits_50',      'consumable',   50,   0,  NULL,  NULL,    NULL,         1,  false),
    ('credits_120',     'consumable',   100,  20, NULL,  NULL,    'popular',    2,  false),
    ('credits_300',     'consumable',   225,  75, NULL,  NULL,    'best_value', 3,  false),
    ('premium_monthly', 'subscription', NULL, 0,  'pro', 'month', NULL,         10, false),
    ('premium_yearly',  'subscription', NULL, 0,  'pro', 'year',  NULL,         11, true)
ON CONFLICT (product_id) DO NOTHING;

-- Plans gain what the Premium page shows. The store product ids move to
-- billing.store_products (one source for the catalog and for verify).
ALTER TABLE billing.plans ADD COLUMN IF NOT EXISTS title TEXT NOT NULL DEFAULT '';
ALTER TABLE billing.plans ADD COLUMN IF NOT EXISTS perks JSONB NOT NULL DEFAULT '[]'::jsonb;
UPDATE billing.plans SET title = 'TieHere Pro',
    perks = '["10 meetups a month included", "Up to 30 people per meetup", "Schedule up to 30 days ahead"]'
WHERE code = 'pro';
ALTER TABLE billing.plans DROP COLUMN IF EXISTS product_ids;

-- A store subscription's product and, in a grace period, when the grace
-- ends. One store subscription belongs to one account: the same original
-- transaction on a second account is the receipt replay plan 3.7 forbids.
ALTER TABLE billing.subscriptions ADD COLUMN IF NOT EXISTS product_id TEXT;
ALTER TABLE billing.subscriptions ADD COLUMN IF NOT EXISTS grace_period_end TIMESTAMPTZ;
CREATE UNIQUE INDEX IF NOT EXISTS idx_subscriptions_store_original
    ON billing.subscriptions (platform, original_transaction_id)
    WHERE original_transaction_id IS NOT NULL;

-- Every verified store transaction. The unique (platform, transaction_id)
-- is what makes a repeated verify a no-op that returns the first result.
CREATE TABLE IF NOT EXISTS billing.store_purchases (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id                 UUID NOT NULL,
    platform                TEXT NOT NULL CHECK (platform IN ('ios', 'android')),
    -- Apple transactionId; Google orderId, or 'token:' + the token hash.
    transaction_id          TEXT NOT NULL,
    -- Apple originalTransactionId; the token hash on Google.
    original_transaction_id TEXT NOT NULL,
    -- sha256 of the Google purchase token, for webhooks. NULL on iOS. The
    -- token itself is never stored, except pending_finish_token below.
    token_hash              TEXT,
    product_id              TEXT NOT NULL,
    kind                    TEXT NOT NULL CHECK (kind IN ('consumable', 'subscription')),
    app_account_token       UUID NOT NULL,
    environment             TEXT NOT NULL CHECK (environment IN ('production', 'sandbox')),
    -- Consumables: what was granted, into which lot.
    credits                 BIGINT,
    lot_id                  UUID,
    -- The store's answer, reduced to known fields; nothing personal.
    raw                     JSONB NOT NULL,
    verified_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Google only: the purchase token, kept just until the consume or
    -- acknowledge call succeeds (the store.finish outbox job needs it),
    -- then set NULL. Google refunds what is not acknowledged in 3 days.
    pending_finish_token    TEXT,
    finished_at             TIMESTAMPTZ,
    -- A store refund or chargeback was applied.
    refunded_at             TIMESTAMPTZ,
    CONSTRAINT store_purchases_transaction UNIQUE (platform, transaction_id)
);
CREATE INDEX IF NOT EXISTS idx_store_purchases_user ON billing.store_purchases (user_id);
CREATE INDEX IF NOT EXISTS idx_store_purchases_token_hash
    ON billing.store_purchases (platform, token_hash) WHERE token_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_store_purchases_original
    ON billing.store_purchases (platform, original_transaction_id);

-- Webhook idempotency: one row per store notification acted on or
-- acknowledged (Apple notificationUUID, Pub/Sub message id). Written in the
-- same transaction as the change it records.
CREATE TABLE IF NOT EXISTS billing.processed_store_notifications (
    platform          TEXT NOT NULL CHECK (platform IN ('ios', 'android')),
    notification_id   TEXT NOT NULL,
    notification_type TEXT NOT NULL,
    subtype           TEXT,
    outcome           TEXT NOT NULL,
    processed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (platform, notification_id)
);
