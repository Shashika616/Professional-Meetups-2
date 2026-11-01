DROP INDEX IF EXISTS analytics.idx_analytics_user_first_seen_first_day;
ALTER TABLE analytics.report_runs
    DROP COLUMN IF EXISTS attempts,
    DROP COLUMN IF EXISTS emailed_at,
    DROP COLUMN IF EXISTS uploaded_at,
    DROP COLUMN IF EXISTS report_uri,
    DROP COLUMN IF EXISTS bytes;
ALTER TABLE analytics.daily_funnel_stats DROP COLUMN IF EXISTS median_step_ms;
DROP TABLE IF EXISTS analytics.daily_credit_band_stats;
DROP TABLE IF EXISTS analytics.daily_abandon_stats;
DROP TABLE IF EXISTS analytics.user_activity_days;
