-- The billing module's credit core (plan 29 §3.1, ADR-010).
--
-- Owned by internal/modules/billing and nothing else. No foreign key leaves
-- this schema and none points into it: user ids and meetup ids are plain
-- UUIDs, the same rule every module follows (ADR-001 §3), so billing can be
-- lifted into its own database later without untangling constraints.
--
-- Credits are integers everywhere (BIGINT). There is no floating point in
-- this schema.
CREATE SCHEMA IF NOT EXISTS billing;

-- One row per user. balance is the sum of the user's open lots; held is the
-- sum of their open credit holds; debt is what a capture after its hold had
-- lapsed could not cover (plan 3.2) — future grants pay it off first.
-- Every write locks this row FOR UPDATE, which is what serialises one
-- user's spends against each other.
CREATE TABLE IF NOT EXISTS billing.wallets (
    user_id    UUID PRIMARY KEY,
    balance    BIGINT NOT NULL DEFAULT 0,
    held       BIGINT NOT NULL DEFAULT 0,
    debt       BIGINT NOT NULL DEFAULT 0,
    version    BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Set when the account is deleted. A closed wallet takes no new holds.
    closed_at  TIMESTAMPTZ,
    CONSTRAINT wallets_non_negative CHECK (balance >= 0 AND held >= 0 AND debt >= 0)
);

-- Every grant is a lot. Spends draw from lots expiring first (plan 3.2), so
-- free credits are used before purchased ones and refunds can go back to
-- the lot they came from.
CREATE TABLE IF NOT EXISTS billing.credit_lots (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id               UUID NOT NULL,
    kind                  TEXT NOT NULL CHECK (kind IN ('welcome', 'purchase', 'promo', 'refund', 'admin')),
    initial               BIGINT NOT NULL CHECK (initial > 0),
    remaining             BIGINT NOT NULL CHECK (remaining >= 0),
    granted_at            TIMESTAMPTZ NOT NULL,
    -- NULL for purchased credits, which never expire (App Review 3.1.1).
    expires_at            TIMESTAMPTZ,
    -- Decay: decay_percent of `initial` every decay_every, applied as a cap
    -- remaining <= initial - floor(initial * percent * k / 100) after k
    -- periods. NULL percent means the lot does not decay.
    decay_percent         INT CHECK (decay_percent IS NULL OR decay_percent BETWEEN 1 AND 100),
    decay_every           INTERVAL,
    decay_periods_applied INT NOT NULL DEFAULT 0 CHECK (decay_periods_applied >= 0),
    next_decay_at         TIMESTAMPTZ,
    source_ref            TEXT,
    CONSTRAINT credit_lots_remaining_le_initial CHECK (remaining <= initial),
    CONSTRAINT credit_lots_decay_complete CHECK (
        (decay_percent IS NULL AND decay_every IS NULL AND next_decay_at IS NULL)
        OR (decay_percent IS NOT NULL AND decay_every IS NOT NULL)
    )
);

-- The spend order itself: earliest expiry first, purchased (NULL) last.
CREATE INDEX IF NOT EXISTS idx_credit_lots_spend_order
    ON billing.credit_lots (user_id, expires_at NULLS LAST, granted_at, id)
    WHERE remaining > 0;
CREATE INDEX IF NOT EXISTS idx_credit_lots_decay_due
    ON billing.credit_lots (next_decay_at)
    WHERE next_decay_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_credit_lots_expiry_due
    ON billing.credit_lots (expires_at)
    WHERE expires_at IS NOT NULL AND remaining > 0;

-- Try-confirm-cancel reservations. A credits hold moves `amount` out of
-- availability (wallets.held) without spending it; a plan_quota hold does
-- the same to plan_usage.held.
CREATE TABLE IF NOT EXISTS billing.holds (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL,
    kind            TEXT NOT NULL CHECK (kind IN ('credits', 'plan_quota')),
    amount          BIGINT NOT NULL CHECK (amount > 0),
    state           TEXT NOT NULL DEFAULT 'held' CHECK (state IN ('held', 'captured', 'released')),
    price_version   INT NOT NULL,
    -- plan_quota holds only: which period's quota they count against.
    period_start    TIMESTAMPTZ,
    expires_at      TIMESTAMPTZ NOT NULL,
    idempotency_key TEXT NOT NULL CHECK (idempotency_key <> ''),
    meetup_id       UUID,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    captured_at     TIMESTAMPTZ,
    released_at     TIMESTAMPTZ,
    -- 'released' (by the caller), 'expired' (by the sweep).
    release_reason  TEXT,
    CONSTRAINT holds_idempotency UNIQUE (user_id, idempotency_key),
    CONSTRAINT holds_quota_has_period CHECK (kind <> 'plan_quota' OR period_start IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_holds_expiry ON billing.holds (expires_at) WHERE state = 'held';

-- Which lots a captured hold drew from, so a refund returns credits to the
-- same lots with their original expiry.
CREATE TABLE IF NOT EXISTS billing.hold_allocations (
    hold_id  UUID NOT NULL REFERENCES billing.holds (id),
    lot_id   UUID NOT NULL REFERENCES billing.credit_lots (id),
    amount   BIGINT NOT NULL CHECK (amount > 0),
    refunded BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (hold_id, lot_id),
    CONSTRAINT hold_allocations_refund_bounded CHECK (refunded >= 0 AND refunded <= amount)
);

-- Append-only. One row per change; replaying delta, held_delta and
-- debt_delta per user gives the wallet's balance, held and debt — the daily
-- reconciliation checks exactly that.
CREATE TABLE IF NOT EXISTS billing.ledger_entries (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         UUID NOT NULL,
    delta           BIGINT NOT NULL DEFAULT 0,
    held_delta      BIGINT NOT NULL DEFAULT 0,
    debt_delta      BIGINT NOT NULL DEFAULT 0,
    reason          TEXT NOT NULL CHECK (reason IN (
        'grant', 'hold', 'capture', 'release', 'decay', 'expire',
        'refund', 'reversal', 'admin_adjust'
    )),
    lot_id          UUID,
    hold_id         UUID,
    ref_type        TEXT,
    ref_id          TEXT,
    balance_after   BIGINT NOT NULL,
    held_after      BIGINT NOT NULL,
    debt_after      BIGINT NOT NULL,
    idempotency_key TEXT NOT NULL CHECK (idempotency_key <> ''),
    -- Set for admin_adjust and admin grants: who did it and why.
    operator        TEXT,
    note            TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ledger_entries_idempotency UNIQUE (user_id, idempotency_key)
);
CREATE INDEX IF NOT EXISTS idx_ledger_entries_user ON billing.ledger_entries (user_id, id DESC);

CREATE OR REPLACE FUNCTION billing.reject_ledger_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'billing.ledger_entries is append-only (% rejected)', TG_OP
        USING ERRCODE = 'insufficient_privilege';
END;
$$;

DROP TRIGGER IF EXISTS ledger_entries_append_only ON billing.ledger_entries;
CREATE TRIGGER ledger_entries_append_only
    BEFORE UPDATE OR DELETE ON billing.ledger_entries
    FOR EACH ROW EXECUTE FUNCTION billing.reject_ledger_change();

-- Versioned pricing documents. Exactly one is active; changing a price is an
-- INSERT of a new version plus flipping `active`, never an edit, so every
-- hold records the version it was priced under.
CREATE TABLE IF NOT EXISTS billing.price_rules (
    version        INT PRIMARY KEY,
    document       JSONB NOT NULL,
    effective_from TIMESTAMPTZ NOT NULL DEFAULT now(),
    active         BOOLEAN NOT NULL DEFAULT false,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by     TEXT NOT NULL DEFAULT 'migration'
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_price_rules_one_active ON billing.price_rules (active) WHERE active;

-- Plan 29 §3.3 and §3.6 defaults (decisions D1-D4, D7). Validated by
-- billing/pricing.Parse at load; a document that fails validation stops
-- pricing rather than charging by a half-read rule.
INSERT INTO billing.price_rules (version, document, active) VALUES (1, '{
    "base": {"credits": 10, "includes_capacity": 4},
    "per_extra_person": 2,
    "lead_time": [
        {"up_to_hours": 48,  "credits": 0},
        {"up_to_hours": 168, "credits": 3},
        {"up_to_hours": 336, "credits": 6},
        {"up_to_hours": 720, "credits": 10}
    ],
    "free": {"max_capacity": 20, "max_advance_days": 14},
    "welcome": {"credits": 60, "decay_percent": 10, "decay_every_days": 7},
    "refunds": {
        "full_if_cancelled_hours_before": 24,
        "no_participants_percent": 50,
        "max_per_30_days": 3
    },
    "hold_ttl_minutes": 120
}', true)
ON CONFLICT (version) DO NOTHING;

CREATE TABLE IF NOT EXISTS billing.plans (
    code             TEXT PRIMARY KEY,
    -- {"ios": ["premium_monthly", ...], "android": [...]}
    product_ids      JSONB NOT NULL DEFAULT '{}'::jsonb,
    period           TEXT NOT NULL CHECK (period IN ('month', 'year', 'manual')),
    meetups_included INT NOT NULL CHECK (meetups_included >= 0),
    max_capacity     INT NOT NULL CHECK (max_capacity BETWEEN 1 AND 30),
    max_advance_days INT NOT NULL CHECK (max_advance_days BETWEEN 1 AND 365),
    active           BOOLEAN NOT NULL DEFAULT true
);

-- D5: one store plan, monthly and yearly. `enterprise` is set by an
-- operator through cmd/billingadmin only; it has no store product.
INSERT INTO billing.plans (code, product_ids, period, meetups_included, max_capacity, max_advance_days) VALUES
    ('pro', '{"ios": ["premium_monthly", "premium_yearly"], "android": ["premium_monthly", "premium_yearly"]}', 'month', 10, 30, 30),
    ('enterprise', '{}', 'manual', 1000, 30, 30)
ON CONFLICT (code) DO NOTHING;

CREATE TABLE IF NOT EXISTS billing.subscriptions (
    user_id                 UUID PRIMARY KEY,
    plan_code               TEXT NOT NULL REFERENCES billing.plans (code),
    status                  TEXT NOT NULL CHECK (status IN (
        'active', 'grace_period', 'past_due', 'canceled', 'expired', 'revoked'
    )),
    -- 'ios' | 'android' for store subscriptions (29B), 'manual' for
    -- operator-set plans.
    platform                TEXT NOT NULL CHECK (platform IN ('ios', 'android', 'manual')),
    original_transaction_id TEXT,
    current_period_start    TIMESTAMPTZ NOT NULL,
    current_period_end      TIMESTAMPTZ NOT NULL,
    auto_renew              BOOLEAN NOT NULL DEFAULT false,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT subscriptions_period_order CHECK (current_period_end > current_period_start)
);

-- Plan quota per billing period. `held` counts open quota holds, `used`
-- captured ones; a reservation needs used + held < meetups_included.
CREATE TABLE IF NOT EXISTS billing.plan_usage (
    user_id      UUID NOT NULL,
    period_start TIMESTAMPTZ NOT NULL,
    used         INT NOT NULL DEFAULT 0 CHECK (used >= 0),
    held         INT NOT NULL DEFAULT 0 CHECK (held >= 0),
    PRIMARY KEY (user_id, period_start)
);

-- One welcome grant per account AND per person: identity_fingerprint is an
-- HMAC of the verified phone (or personal email) supplied by the auth
-- module, so several accounts for one person get one grant between them.
-- Kept when an account is deleted, so deleting and re-creating does not
-- reset it.
CREATE TABLE IF NOT EXISTS billing.welcome_grants (
    user_id              UUID PRIMARY KEY,
    identity_fingerprint TEXT NOT NULL UNIQUE,
    lot_id               UUID NOT NULL,
    amount               BIGINT NOT NULL,
    granted_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Outbox for effects other modules see (credits.changed now; subscription
-- events in 29B; analytics domain events in 29D). Same shape and claiming
-- strategy as meetup.meetups_completed_outbox.
CREATE TABLE IF NOT EXISTS billing.billing_outbox (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    topic            TEXT NOT NULL,
    payload          JSONB NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at     TIMESTAMPTZ,
    attempts         INT NOT NULL DEFAULT 0,
    next_attempt_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    dead_lettered_at TIMESTAMPTZ,
    last_error       TEXT
);
CREATE INDEX IF NOT EXISTS idx_billing_outbox_claimable
    ON billing.billing_outbox (next_attempt_at)
    WHERE processed_at IS NULL AND dead_lettered_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_billing_outbox_retention
    ON billing.billing_outbox (processed_at) WHERE processed_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_billing_outbox_dead_lettered
    ON billing.billing_outbox (dead_lettered_at) WHERE dead_lettered_at IS NOT NULL;

-- One row per refund decision, including the ones that refunded nothing.
-- Unique per hold: a meetup's end is refunded at most once however many
-- times its event is delivered. The 3-per-30-days cap counts outcome
-- 'refunded'.
CREATE TABLE IF NOT EXISTS billing.refund_log (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id    UUID NOT NULL,
    hold_id    UUID NOT NULL UNIQUE,
    meetup_id  UUID,
    event      TEXT NOT NULL CHECK (event IN ('cancelled', 'closed')),
    outcome    TEXT NOT NULL CHECK (outcome IN ('refunded', 'no_refund', 'skipped_cap', 'released')),
    percent    INT NOT NULL CHECK (percent BETWEEN 0 AND 100),
    amount     BIGINT NOT NULL CHECK (amount >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_refund_log_user_recent ON billing.refund_log (user_id, created_at DESC);

-- Operator actions that are not ledger entries (set-plan, account closure),
-- written by cmd/billingadmin and the deletion consumer.
CREATE TABLE IF NOT EXISTS billing.admin_audit (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id    UUID NOT NULL,
    action     TEXT NOT NULL,
    detail     JSONB NOT NULL DEFAULT '{}'::jsonb,
    operator   TEXT NOT NULL CHECK (operator <> ''),
    reason     TEXT NOT NULL CHECK (reason <> ''),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One row per daily reconciliation run (plan 3.2), with the mismatches it
-- found, for the daily report (29F).
CREATE TABLE IF NOT EXISTS billing.reconciliation_runs (
    run_date    DATE PRIMARY KEY,
    checked     INT NOT NULL,
    mismatches  INT NOT NULL,
    detail      JSONB NOT NULL DEFAULT '[]'::jsonb,
    finished_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
