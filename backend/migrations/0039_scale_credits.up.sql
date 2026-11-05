-- Credits become bigger numbers: a 1000 credit welcome and every price x15.
-- The value of a credit changes, not what anything costs in real money: store
-- packs keep their prices and product ids, and give 15 times the credits.
--
-- The welcome is 1000, not 60 x 15 = 900, which is slightly more generous.
-- The ledger is append-only and untouched: past entries stay as they were, and
-- a refund returns what was actually charged. Existing balances are not
-- changed here; see the runbook.
UPDATE billing.price_rules SET active = false WHERE active;

INSERT INTO billing.price_rules (version, document, active) VALUES (2, '{
    "base": {"credits": 150, "includes_capacity": 4},
    "per_extra_person": 30,
    "lead_time": [
        {"up_to_hours": 48,  "credits": 0},
        {"up_to_hours": 168, "credits": 45},
        {"up_to_hours": 336, "credits": 90},
        {"up_to_hours": 720, "credits": 150}
    ],
    "free": {"max_capacity": 20, "max_advance_days": 14},
    "welcome": {"credits": 1000, "decay_percent": 10, "decay_every_days": 7},
    "refunds": {
        "full_if_cancelled_hours_before": 24,
        "no_participants_percent": 50,
        "max_per_30_days": 3
    },
    "hold_ttl_minutes": 120
}', true)
ON CONFLICT (version) DO NOTHING;

UPDATE billing.store_products
SET credits = credits * 15, bonus = bonus * 15
WHERE kind = 'consumable' AND product_id IN ('credits_50', 'credits_120', 'credits_300');
