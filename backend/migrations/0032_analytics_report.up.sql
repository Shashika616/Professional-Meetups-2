-- Plan 29F: what the daily report needs beyond 0030's aggregates.
--
-- Days are Asia/Colombo calendar days from here on (the report's time
-- zone); raw partitions stay UTC days.

-- Which accounts were active on each day: WAU, MAU, retention and the
-- weekly cohorts cannot be summed from daily distinct counts. Pseudonymous
-- keys only, removed with the account (deletion, opt-out) and after 120
-- days by the retention sweep. Never shown: the report prints counts.
CREATE TABLE IF NOT EXISTS analytics.user_activity_days (
    day      DATE NOT NULL,
    user_key TEXT NOT NULL,
    PRIMARY KEY (day, user_key)
);
CREATE INDEX IF NOT EXISTS idx_analytics_user_activity_days_user_key ON analytics.user_activity_days (user_key);

-- Cohort and retention reads filter accounts by the day first seen (a
-- sequential scan of every account without this; 29F scalability check).
CREATE INDEX IF NOT EXISTS idx_analytics_user_first_seen_first_day ON analytics.user_first_seen (first_day);

-- Abandoned flows by the step they stopped at and why (backgrounded or not).
CREATE TABLE IF NOT EXISTS analytics.daily_abandon_stats (
    day     DATE   NOT NULL,
    flow_id TEXT   NOT NULL,
    step    TEXT   NOT NULL,
    reason  TEXT   NOT NULL,
    count   BIGINT NOT NULL,
    PRIMARY KEY (day, flow_id, step, reason)
);

-- Credits spent by price band.
CREATE TABLE IF NOT EXISTS analytics.daily_credit_band_stats (
    day     DATE   NOT NULL,
    band    TEXT   NOT NULL,
    events  BIGINT NOT NULL,
    credits BIGINT NOT NULL,
    PRIMARY KEY (day, band)
);

-- Median time between a step being viewed and completed.
ALTER TABLE analytics.daily_funnel_stats ADD COLUMN IF NOT EXISTS median_step_ms BIGINT;

-- The report's delivery, tracked per part so a retry repeats only what
-- failed (an email already sent is not sent twice).
ALTER TABLE analytics.report_runs
    ADD COLUMN IF NOT EXISTS attempts    INT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS emailed_at  TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS uploaded_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS report_uri  TEXT,
    ADD COLUMN IF NOT EXISTS bytes       BIGINT;
