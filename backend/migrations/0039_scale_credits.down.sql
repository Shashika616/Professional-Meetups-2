UPDATE billing.store_products
SET credits = credits / 15, bonus = bonus / 15
WHERE kind = 'consumable' AND product_id IN ('credits_50', 'credits_120', 'credits_300');

DELETE FROM billing.price_rules WHERE version = 2;
UPDATE billing.price_rules SET active = true WHERE version = 1;
