-- The daily report's reads (plan 29F). Aggregates only: every query here
-- returns counts, never a user_key.

-- name: ReportActiveUsers :one
-- Distinct accounts active from from_day to to_day (DAU, WAU, MAU).
SELECT count(DISTINCT user_key)::bigint AS users
FROM analytics.user_activity_days
WHERE day BETWEEN sqlc.arg(from_day)::date AND sqlc.arg(to_day)::date;

-- name: ReportDailyActive :many
SELECT day, count(*)::bigint AS users
FROM analytics.user_activity_days
WHERE day BETWEEN sqlc.arg(from_day)::date AND sqlc.arg(to_day)::date
GROUP BY day
ORDER BY day;

-- name: ReportNewUsers :one
SELECT count(*)::bigint AS users FROM analytics.user_first_seen WHERE first_day = sqlc.arg(day)::date;

-- name: ReportRetention :one
-- Of the accounts first seen on cohort_day, how many were active on active_day.
SELECT count(*)::bigint AS cohort,
       count(a.user_key)::bigint AS retained
FROM analytics.user_first_seen f
LEFT JOIN analytics.user_activity_days a ON a.user_key = f.user_key AND a.day = sqlc.arg(active_day)::date
WHERE f.first_day = sqlc.arg(cohort_day)::date;

-- name: ReportSessions :many
SELECT day, sessions, users, signed_in_users, median_session_ms, mean_session_ms
FROM analytics.daily_session_stats
WHERE day = sqlc.arg(day)::date;

-- name: ReportScreens :many
SELECT screen, views, unique_users, median_ms, p90_ms, bounces, exits
FROM analytics.daily_screen_stats
WHERE day = sqlc.arg(day)::date
ORDER BY views DESC, screen;

-- name: ReportFeatures :many
SELECT feature, uses, unique_users
FROM analytics.daily_feature_stats
WHERE day = sqlc.arg(day)::date
ORDER BY uses DESC, feature;

-- name: ReportFeaturesUsed :many
-- Every feature used at least once from from_day to to_day.
SELECT DISTINCT feature
FROM analytics.daily_feature_stats
WHERE day BETWEEN sqlc.arg(from_day)::date AND sqlc.arg(to_day)::date AND uses > 0;

-- name: ReportFunnels :many
SELECT flow_id, step, entered, completed, abandoned, median_step_ms
FROM analytics.daily_funnel_stats
WHERE day = sqlc.arg(day)::date
ORDER BY flow_id, step;

-- name: ReportErrors :many
SELECT kind, screen, detail, count
FROM analytics.daily_error_stats
WHERE day = sqlc.arg(day)::date
ORDER BY count DESC, kind, screen, detail;

-- name: ReportAbandons :many
SELECT flow_id, step, reason, count
FROM analytics.daily_abandon_stats
WHERE day = sqlc.arg(day)::date
ORDER BY flow_id, count DESC, step, reason;

-- name: ReportCredits :many
SELECT event_name, detail, events, users, credits
FROM analytics.daily_credit_stats
WHERE day = sqlc.arg(day)::date
ORDER BY event_name, detail;

-- name: ReportCreditBands :many
SELECT band, events, credits
FROM analytics.daily_credit_band_stats
WHERE day = sqlc.arg(day)::date
ORDER BY band;

-- name: ReportCohorts :many
-- Weekly cohorts (by the Monday of the week first seen) and how many of
-- each were active in each later week, for cohorts from from_week on.
SELECT date_trunc('week', f.first_day)::date AS cohort_week,
       ((date_trunc('week', a.day)::date - date_trunc('week', f.first_day)::date) / 7)::int AS week_offset,
       count(DISTINCT f.user_key)::bigint AS users
FROM analytics.user_first_seen f
JOIN analytics.user_activity_days a ON a.user_key = f.user_key AND a.day >= f.first_day
WHERE f.first_day >= sqlc.arg(from_week)::date AND a.day <= sqlc.arg(to_day)::date
GROUP BY 1, 2
ORDER BY 1, 2;

-- name: ReportCohortSizes :many
SELECT date_trunc('week', first_day)::date AS cohort_week, count(*)::bigint AS users
FROM analytics.user_first_seen
WHERE first_day >= sqlc.arg(from_week)::date AND first_day <= sqlc.arg(to_day)::date
GROUP BY 1
ORDER BY 1;

-- name: ClaimReportRun :one
-- Claims the day's run unless it is done or another tick holds it (a
-- running claim older than 15 minutes is taken over: that tick died).
-- Returns what was already delivered, so a retry repeats only the rest.
INSERT INTO analytics.report_runs (day, status, attempts)
VALUES (sqlc.arg(day)::date, 'running', 1)
ON CONFLICT (day) DO UPDATE
SET status = 'running', started_at = now(), attempts = analytics.report_runs.attempts + 1
WHERE analytics.report_runs.attempts < sqlc.arg(max_attempts)::int
  AND (analytics.report_runs.status = 'failed'
       OR (analytics.report_runs.status = 'running' AND analytics.report_runs.started_at < now() - interval '15 minutes'))
RETURNING attempts, emailed_at, uploaded_at;

-- name: GetReportRun :many
SELECT day, status, attempts, started_at, finished_at, emailed_at, uploaded_at, report_uri, bytes, detail
FROM analytics.report_runs
WHERE day = sqlc.arg(day)::date;

-- name: MarkReportEmailed :exec
UPDATE analytics.report_runs SET emailed_at = now() WHERE day = sqlc.arg(day)::date;

-- name: MarkReportUploaded :exec
UPDATE analytics.report_runs SET uploaded_at = now(), report_uri = sqlc.arg(uri) WHERE day = sqlc.arg(day)::date;

-- name: FinishReportRun :exec
UPDATE analytics.report_runs
SET status = sqlc.arg(status), finished_at = now(), bytes = sqlc.arg(bytes), detail = sqlc.narg(detail)
WHERE day = sqlc.arg(day)::date;

-- name: UpsertRegeneratedReport :exec
-- The regeneration CLI: records the day as done, whatever it was.
INSERT INTO analytics.report_runs (day, status, attempts, finished_at, bytes)
VALUES (sqlc.arg(day)::date, 'done', 1, now(), sqlc.arg(bytes))
ON CONFLICT (day) DO UPDATE
SET status = 'done', finished_at = now(), bytes = EXCLUDED.bytes, detail = NULL,
    attempts = analytics.report_runs.attempts + 1;
