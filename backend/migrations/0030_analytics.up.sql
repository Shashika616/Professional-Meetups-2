-- Plan 29D: the analytics module's schema (plan 29 §4.3, ADR-011).
--
-- PRIVACY: no column here holds a name, email, phone, free text, meetup
-- title or label, coordinate, IP address, receipt, or raw user id. The only
-- account identifier is user_key, an HMAC-SHA256 of the user id under a
-- secret the database never sees. Attributes are typed and allowlisted by
-- the registry before they get here.
CREATE SCHEMA IF NOT EXISTS analytics;

-- Raw events, one partition per server day (received_day, UTC). The
-- primary key includes the partition key, as Postgres requires; within a
-- day it is what stores a repeated event_id once.
CREATE TABLE IF NOT EXISTS analytics.events (
    received_day   DATE        NOT NULL,
    event_id       UUID        NOT NULL,
    event_name     TEXT        NOT NULL,
    schema_version INT         NOT NULL,
    source         TEXT        NOT NULL CHECK (source IN ('app', 'server')),
    occurred_at    TIMESTAMPTZ NOT NULL,
    received_at    TIMESTAMPTZ NOT NULL,
    user_key       TEXT,
    install_id     TEXT,
    session_id     TEXT,
    app_version    TEXT,
    os_name        TEXT,
    os_version     TEXT,
    device_class   TEXT,
    locale         TEXT,
    screen         TEXT,
    flow_id        TEXT,
    flow_step      TEXT,
    attributes     JSONB       NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (received_day, event_id)
) PARTITION BY RANGE (received_day);

CREATE INDEX IF NOT EXISTS idx_analytics_events_received_brin ON analytics.events USING BRIN (received_at);
CREATE INDEX IF NOT EXISTS idx_analytics_events_name_received ON analytics.events (event_name, received_at);
CREATE INDEX IF NOT EXISTS idx_analytics_events_user_key ON analytics.events (user_key) WHERE user_key IS NOT NULL;

-- Rows for a day with no partition yet land here instead of failing the
-- flush. The partition sweep runs three days ahead, so this should stay
-- empty; it is never dropped.
CREATE TABLE IF NOT EXISTS analytics.events_default PARTITION OF analytics.events DEFAULT;

-- Partition maintenance state: created, archived to Cloud Storage, dropped.
CREATE TABLE IF NOT EXISTS analytics.partitions (
    day         DATE PRIMARY KEY,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_at TIMESTAMPTZ,
    archive_uri TEXT,
    dropped_at  TIMESTAMPTZ
);

-- Creates the partition for one day, idempotently, and reports whether it
-- made one. Serialised by an advisory lock so two overlapping ticks cannot
-- race on the CREATE. Rows that already landed in the default partition for
-- that day would make a plain CREATE ... PARTITION OF fail, so the
-- partition is built detached, those rows are moved in, and it is attached.
CREATE OR REPLACE FUNCTION analytics.ensure_partition(d DATE) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
    part TEXT := 'events_' || to_char(d, 'YYYYMMDD');
    made BOOLEAN := false;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('analytics.partitions'));
    IF to_regclass('analytics.' || part) IS NULL THEN
        EXECUTE format('CREATE TABLE analytics.%I (LIKE analytics.events INCLUDING DEFAULTS INCLUDING CONSTRAINTS)', part);
        EXECUTE format('INSERT INTO analytics.%I SELECT * FROM analytics.events_default WHERE received_day = %L', part, d);
        DELETE FROM analytics.events_default WHERE received_day = d;
        EXECUTE format('ALTER TABLE analytics.events ATTACH PARTITION analytics.%I FOR VALUES FROM (%L) TO (%L)',
                       part, d, d + 1);
        made := true;
    END IF;
    INSERT INTO analytics.partitions (day) VALUES (d)
    ON CONFLICT (day) DO UPDATE SET dropped_at = NULL WHERE analytics.partitions.dropped_at IS NOT NULL;
    RETURN made;
END;
$$;

-- Drops one day's partition, idempotently, and records it.
CREATE OR REPLACE FUNCTION analytics.drop_partition(d DATE) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
    part TEXT := 'events_' || to_char(d, 'YYYYMMDD');
    dropped BOOLEAN := false;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('analytics.partitions'));
    IF to_regclass('analytics.' || part) IS NOT NULL THEN
        EXECUTE format('DROP TABLE analytics.%I', part);
        dropped := true;
    END IF;
    UPDATE analytics.partitions SET dropped_at = now() WHERE day = d AND dropped_at IS NULL;
    RETURN dropped;
END;
$$;

-- Server-side opt-out (PUT /v1/analytics/consent): events carrying this
-- user_key are dropped.
CREATE TABLE IF NOT EXISTS analytics.opt_outs (
    user_key   TEXT PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Which days have been aggregated (the aggregation is idempotent by date).
CREATE TABLE IF NOT EXISTS analytics.aggregate_runs (
    day           DATE PRIMARY KEY,
    aggregated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    events        BIGINT      NOT NULL
);

-- Daily aggregates, kept after the raw partitions are dropped. Per-screen,
-- per-feature, per-flow and per-error counts; nothing per user except
-- user_first_seen, which account deletion removes.
CREATE TABLE IF NOT EXISTS analytics.daily_screen_stats (
    day          DATE   NOT NULL,
    screen       TEXT   NOT NULL,
    views        BIGINT NOT NULL,
    unique_users BIGINT NOT NULL,
    median_ms    BIGINT,
    p90_ms       BIGINT,
    bounces      BIGINT NOT NULL,
    exits        BIGINT NOT NULL,
    PRIMARY KEY (day, screen)
);

CREATE TABLE IF NOT EXISTS analytics.daily_feature_stats (
    day          DATE   NOT NULL,
    feature      TEXT   NOT NULL,
    uses         BIGINT NOT NULL,
    unique_users BIGINT NOT NULL,
    PRIMARY KEY (day, feature)
);

-- step '' is the flow as a whole (started, completed, abandoned).
CREATE TABLE IF NOT EXISTS analytics.daily_funnel_stats (
    day       DATE   NOT NULL,
    flow_id   TEXT   NOT NULL,
    step      TEXT   NOT NULL,
    entered   BIGINT NOT NULL,
    completed BIGINT NOT NULL,
    abandoned BIGINT NOT NULL,
    PRIMARY KEY (day, flow_id, step)
);

CREATE TABLE IF NOT EXISTS analytics.daily_session_stats (
    day               DATE   PRIMARY KEY,
    sessions          BIGINT NOT NULL,
    users             BIGINT NOT NULL,
    signed_in_users   BIGINT NOT NULL,
    median_session_ms BIGINT,
    mean_session_ms   BIGINT
);

CREATE TABLE IF NOT EXISTS analytics.daily_error_stats (
    day    DATE   NOT NULL,
    kind   TEXT   NOT NULL,
    screen TEXT   NOT NULL,
    detail TEXT   NOT NULL,
    count  BIGINT NOT NULL,
    PRIMARY KEY (day, kind, screen, detail)
);

CREATE TABLE IF NOT EXISTS analytics.daily_credit_stats (
    day        DATE   NOT NULL,
    event_name TEXT   NOT NULL,
    detail     TEXT   NOT NULL,
    events     BIGINT NOT NULL,
    users      BIGINT NOT NULL,
    credits    BIGINT NOT NULL,
    PRIMARY KEY (day, event_name, detail)
);

-- For weekly cohorts: the first day each account was seen.
CREATE TABLE IF NOT EXISTS analytics.user_first_seen (
    user_key  TEXT PRIMARY KEY,
    first_day DATE NOT NULL
);

-- The daily report's runs (plan 29F), idempotent by date.
CREATE TABLE IF NOT EXISTS analytics.report_runs (
    day         DATE PRIMARY KEY,
    status      TEXT NOT NULL CHECK (status IN ('running', 'done', 'failed')),
    started_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at TIMESTAMPTZ,
    detail      TEXT
);

