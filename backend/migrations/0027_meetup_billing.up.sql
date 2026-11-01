-- The meetup side of charging for creation (plan 29 §3.5, §3.6).
--
-- Columns on meetup.meetups are safe for the revision already serving: sqlc
-- expands every `*` into an explicit column list at generate time, so the
-- old code neither reads nor writes these and an INSERT that omits them
-- gets NULL.

-- Widened from 1..20 so a plan can host 30 (plan 3.4). The per-user limit
-- (20 without a plan) is enforced by the service, not here.
ALTER TABLE meetup.meetups DROP CONSTRAINT IF EXISTS meetups_capacity_check;
ALTER TABLE meetup.meetups ADD CONSTRAINT meetups_capacity_check CHECK (capacity BETWEEN 1 AND 30);

-- The client's Idempotency-Key for the create request. A retry with the
-- same key finds this row and gets the original meetup back, charging
-- nothing more. NULL for meetups created without one (every old client).
ALTER TABLE meetup.meetups ADD COLUMN IF NOT EXISTS creation_key TEXT
    CHECK (creation_key IS NULL OR (length(creation_key) BETWEEN 1 AND 128));
-- The billing hold this meetup's creation reserved. NULL when creation was
-- free (created before credits, or with no charger wired). A plain UUID: billing's tables are not
-- referenced from here (ADR-001 §3).
ALTER TABLE meetup.meetups ADD COLUMN IF NOT EXISTS charge_hold_id UUID;

CREATE UNIQUE INDEX IF NOT EXISTS idx_meetups_host_creation_key
    ON meetup.meetups (host_user_id, creation_key)
    WHERE creation_key IS NOT NULL;

-- meetup.created / meetup.cancelled / meetup.closed for charged meetups,
-- written in the same transaction as the change they describe. Drained by
-- a poller in cmd/monolith that hands each event to the billing module
-- (capture on created; the refund policy on cancelled and closed).
CREATE TABLE IF NOT EXISTS meetup.billing_outbox (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    topic            TEXT NOT NULL CHECK (topic IN ('meetup.created', 'meetup.cancelled', 'meetup.closed')),
    payload          JSONB NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at     TIMESTAMPTZ,
    attempts         INT NOT NULL DEFAULT 0,
    next_attempt_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    dead_lettered_at TIMESTAMPTZ,
    last_error       TEXT
);
CREATE INDEX IF NOT EXISTS idx_meetup_billing_outbox_claimable
    ON meetup.billing_outbox (next_attempt_at)
    WHERE processed_at IS NULL AND dead_lettered_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_meetup_billing_outbox_retention
    ON meetup.billing_outbox (processed_at) WHERE processed_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_meetup_billing_outbox_dead_lettered
    ON meetup.billing_outbox (dead_lettered_at) WHERE dead_lettered_at IS NOT NULL;
