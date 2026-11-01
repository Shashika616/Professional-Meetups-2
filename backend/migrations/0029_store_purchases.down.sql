DROP TABLE IF EXISTS billing.processed_store_notifications;
DROP TABLE IF EXISTS billing.store_purchases;

DROP INDEX IF EXISTS billing.idx_subscriptions_store_original;
ALTER TABLE billing.subscriptions DROP COLUMN IF EXISTS grace_period_end;
ALTER TABLE billing.subscriptions DROP COLUMN IF EXISTS product_id;

ALTER TABLE billing.plans ADD COLUMN IF NOT EXISTS product_ids JSONB NOT NULL DEFAULT '{}'::jsonb;
UPDATE billing.plans
SET product_ids = '{"ios": ["premium_monthly", "premium_yearly"], "android": ["premium_monthly", "premium_yearly"]}'
WHERE code = 'pro';
ALTER TABLE billing.plans DROP COLUMN IF EXISTS perks;
ALTER TABLE billing.plans DROP COLUMN IF EXISTS title;

DROP TABLE IF EXISTS billing.store_products;
