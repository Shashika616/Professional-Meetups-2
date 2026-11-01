-- Remote config and feature flags (plan 29 §2, ADR-012).
--
-- Schema `ops`: the flags are served by the ops service (GET /v1/app-config)
-- and read by every module through internal/platform/flags, so they belong
-- to no single module's schema.
--
-- Evaluation (internal/platform/flags.Evaluate): rules run in order and the
-- first one that matches decides; a flag no rule matches is `enabled`.
-- Rule shapes, all JSON objects with a "type":
--   {"type":"user_ids","values":["<uuid>",...]}
--   {"type":"email_domains","values":["meetups.test",...]}
--   {"type":"min_app_version","version":"1.4.0"}
--   {"type":"percentage","percent":10}
-- Each may carry "result": false to switch a matching subject OFF; the
-- default result of a match is true.
CREATE SCHEMA IF NOT EXISTS ops;

CREATE TABLE IF NOT EXISTS ops.feature_flags (
    key        TEXT PRIMARY KEY CHECK (key ~ '^[a-z0-9_.]{1,64}$'),
    enabled    BOOLEAN NOT NULL DEFAULT false,
    rules      JSONB NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(rules) = 'array'),
    -- An optional non-boolean payload (analytics.sample_rate's 100), handed
    -- to the client as-is next to the evaluated boolean.
    value      JSONB,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by TEXT NOT NULL DEFAULT 'migration'
);

-- Every change made through cmd/billingadmin, with who and why. There is no
-- HTTP surface that can change a flag (plan 29 §1).
CREATE TABLE IF NOT EXISTS ops.feature_flag_audit (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    key        TEXT NOT NULL,
    before     JSONB,
    after      JSONB NOT NULL,
    operator   TEXT NOT NULL CHECK (operator <> ''),
    reason     TEXT NOT NULL CHECK (reason <> ''),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The flags plan 29 introduces. Credits have none: hosts use and buy them
-- from day one. Subscription plans launch later, so billing.plans.visible
-- starts OFF; it is on for the seeded @meetups.test fixtures
-- (backend/testdata/seed-test-users.sql) so hidden plans can be tested in
-- production; nobody else sees them until the flag is turned on.
INSERT INTO ops.feature_flags (key, enabled, rules, value) VALUES
    ('billing.plans.visible', false, '[
        {"type":"email_domains","values":["meetups.test"]},
        {"type":"user_ids","values":[
            "00000000-0000-4000-8000-000000000010",
            "00000000-0000-4000-8000-000000000011",
            "00000000-0000-4000-8000-000000000020",
            "00000000-0000-4000-8000-000000000021",
            "00000000-0000-4000-8000-000000000030",
            "00000000-0000-4000-8000-000000000031",
            "00000000-0000-4000-8000-000000000040",
            "00000000-0000-4000-8000-000000000041"
        ]}
    ]', NULL),
    ('analytics.enabled', true, '[]', NULL),
    ('analytics.sample_rate', true, '[]', '100')
ON CONFLICT (key) DO NOTHING;
