-- Plan 29D: meetup.activity_outbox, a durable record of join requests and
-- accepts for analytics, written in the same transaction as the request or
-- the accept. Before this, the only durable record outside the meetup
-- schema was the notification outbox, which has no row when the recipient
-- has no registered device, so analytics undercounted both.
--
-- The payload carries ids only (request, meetup, requester, host): no
-- names, no text. Same claiming columns and indexes as the other meetup
-- outboxes.
CREATE TABLE IF NOT EXISTS meetup.activity_outbox (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    topic            TEXT NOT NULL CHECK (topic IN ('request.created', 'request.accepted')),
    payload          JSONB NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at     TIMESTAMPTZ,
    attempts         INT NOT NULL DEFAULT 0,
    next_attempt_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    dead_lettered_at TIMESTAMPTZ,
    last_error       TEXT
);
CREATE INDEX IF NOT EXISTS idx_meetup_activity_outbox_claimable
    ON meetup.activity_outbox (next_attempt_at)
    WHERE processed_at IS NULL AND dead_lettered_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_meetup_activity_outbox_retention
    ON meetup.activity_outbox (processed_at) WHERE processed_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_meetup_activity_outbox_dead_lettered
    ON meetup.activity_outbox (dead_lettered_at) WHERE dead_lettered_at IS NOT NULL;
