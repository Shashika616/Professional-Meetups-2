-- name: EnsurePartition :one
SELECT analytics.ensure_partition(sqlc.arg(day)::date)::boolean AS made;

-- name: DropPartition :one
SELECT analytics.drop_partition(sqlc.arg(day)::date)::boolean AS dropped;

-- name: ListPartitionsBefore :many
-- Live partitions older than the retention cut-off, oldest first.
SELECT day, archived_at, archive_uri
FROM analytics.partitions
WHERE dropped_at IS NULL AND day < sqlc.arg(before)::date
ORDER BY day;

-- name: MarkPartitionArchived :exec
UPDATE analytics.partitions
SET archived_at = now(), archive_uri = sqlc.arg(uri)
WHERE day = sqlc.arg(day)::date;

-- name: IsAggregated :one
SELECT EXISTS (SELECT 1 FROM analytics.aggregate_runs WHERE day = sqlc.arg(day)::date) AS aggregated;

-- name: ListDaysToAggregate :many
-- Complete days (before today) with a live partition and no aggregate yet.
SELECT p.day
FROM analytics.partitions p
LEFT JOIN analytics.aggregate_runs a ON a.day = p.day
WHERE a.day IS NULL AND p.dropped_at IS NULL AND p.day < sqlc.arg(today)::date
ORDER BY p.day;

-- name: CountPartitionEvents :one
SELECT count(*)::bigint AS events FROM analytics.events WHERE received_day BETWEEN sqlc.arg(day)::date - 1 AND sqlc.arg(day)::date
      AND received_at >= (sqlc.arg(day)::date)::timestamp AT TIME ZONE 'Asia/Colombo'
      AND received_at < (sqlc.arg(day)::date + 1)::timestamp AT TIME ZONE 'Asia/Colombo';

-- name: InsertAggregateRun :exec
INSERT INTO analytics.aggregate_runs (day, events) VALUES (sqlc.arg(day)::date, sqlc.arg(events))
ON CONFLICT (day) DO UPDATE SET aggregated_at = now(), events = EXCLUDED.events;

-- name: DeleteScreenStats :exec
DELETE FROM analytics.daily_screen_stats WHERE day = sqlc.arg(day)::date;

-- name: DeleteFeatureStats :exec
DELETE FROM analytics.daily_feature_stats WHERE day = sqlc.arg(day)::date;

-- name: DeleteFunnelStats :exec
DELETE FROM analytics.daily_funnel_stats WHERE day = sqlc.arg(day)::date;

-- name: DeleteSessionStats :exec
DELETE FROM analytics.daily_session_stats WHERE day = sqlc.arg(day)::date;

-- name: DeleteErrorStats :exec
DELETE FROM analytics.daily_error_stats WHERE day = sqlc.arg(day)::date;

-- name: DeleteCreditStats :exec
DELETE FROM analytics.daily_credit_stats WHERE day = sqlc.arg(day)::date;

-- name: AggregateScreens :execrows
-- Per screen: views and unique viewers (screen_viewed), median and p90 time
-- on screen and bounces under 3 seconds (screen_left), and exits: sessions
-- whose last screen this was. An actor is the account when signed in,
-- otherwise the install.
WITH d AS (
    SELECT * FROM analytics.events
    WHERE received_day BETWEEN sqlc.arg(day)::date - 1 AND sqlc.arg(day)::date
      AND received_at >= (sqlc.arg(day)::date)::timestamp AT TIME ZONE 'Asia/Colombo'
      AND received_at < (sqlc.arg(day)::date + 1)::timestamp AT TIME ZONE 'Asia/Colombo' AND screen IS NOT NULL AND screen <> ''
), viewed AS (
    SELECT screen, count(*) AS views, count(DISTINCT coalesce(user_key, install_id)) AS unique_users
    FROM d WHERE event_name = 'screen_viewed' GROUP BY screen
), left_screen AS (
    SELECT screen,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY (attributes ->> 'duration_ms')::bigint) AS median_ms,
           percentile_cont(0.9) WITHIN GROUP (ORDER BY (attributes ->> 'duration_ms')::bigint) AS p90_ms,
           count(*) FILTER (WHERE (attributes ->> 'duration_ms')::bigint < 3000) AS bounces
    FROM d WHERE event_name = 'screen_left' AND attributes ->> 'duration_ms' IS NOT NULL
    GROUP BY screen
), last_screen AS (
    SELECT DISTINCT ON (session_id) session_id, screen
    FROM d WHERE event_name = 'screen_viewed' AND session_id IS NOT NULL AND session_id <> ''
    ORDER BY session_id, occurred_at DESC, event_id DESC
), exits AS (
    SELECT screen, count(*) AS exits FROM last_screen GROUP BY screen
)
INSERT INTO analytics.daily_screen_stats (day, screen, views, unique_users, median_ms, p90_ms, bounces, exits)
SELECT sqlc.arg(day)::date, v.screen, v.views, v.unique_users,
       round(l.median_ms)::bigint, round(l.p90_ms)::bigint,
       coalesce(l.bounces, 0), coalesce(e.exits, 0)
FROM viewed v
LEFT JOIN left_screen l ON l.screen = v.screen
LEFT JOIN exits e ON e.screen = v.screen;

-- name: AggregateFeatures :execrows
-- Per catalogued control (cta_tapped), and search, filters and toggles.
WITH d AS (
    SELECT coalesce(user_key, install_id) AS actor,
           CASE event_name
               WHEN 'cta_tapped' THEN attributes ->> 'cta'
               WHEN 'search_performed' THEN 'search'
               WHEN 'filter_changed' THEN 'filter:' || coalesce(attributes ->> 'filter', '')
               WHEN 'toggle_changed' THEN 'toggle:' || coalesce(attributes ->> 'toggle', '')
           END AS feature
    FROM analytics.events
    WHERE received_day BETWEEN sqlc.arg(day)::date - 1 AND sqlc.arg(day)::date
      AND received_at >= (sqlc.arg(day)::date)::timestamp AT TIME ZONE 'Asia/Colombo'
      AND received_at < (sqlc.arg(day)::date + 1)::timestamp AT TIME ZONE 'Asia/Colombo'
      AND event_name IN ('cta_tapped', 'search_performed', 'filter_changed', 'toggle_changed')
)
INSERT INTO analytics.daily_feature_stats (day, feature, uses, unique_users)
SELECT sqlc.arg(day)::date, feature, count(*), count(DISTINCT actor)
FROM d WHERE feature IS NOT NULL
GROUP BY feature;

-- name: AggregateFunnels :execrows
-- Per flow (step '') and per step: entered, completed, abandoned, and the
-- median time from a step being viewed to completed.
WITH d AS (
    SELECT event_name, flow_id, coalesce(flow_step, '') AS step, attributes
    FROM analytics.events
    WHERE received_day BETWEEN sqlc.arg(day)::date - 1 AND sqlc.arg(day)::date
      AND received_at >= (sqlc.arg(day)::date)::timestamp AT TIME ZONE 'Asia/Colombo'
      AND received_at < (sqlc.arg(day)::date + 1)::timestamp AT TIME ZONE 'Asia/Colombo'
      AND flow_id IS NOT NULL AND flow_id <> ''
      AND event_name IN ('flow_started', 'flow_step_viewed', 'flow_step_completed', 'flow_completed', 'flow_abandoned')
), rows AS (
    SELECT flow_id, '' AS step,
           (event_name = 'flow_started')::int AS entered,
           (event_name = 'flow_completed')::int AS completed,
           (event_name = 'flow_abandoned')::int AS abandoned
    FROM d WHERE event_name IN ('flow_started', 'flow_completed', 'flow_abandoned')
    UNION ALL
    SELECT flow_id, step,
           (event_name = 'flow_step_viewed')::int,
           (event_name = 'flow_step_completed')::int,
           (event_name = 'flow_abandoned')::int
    FROM d WHERE step <> '' AND event_name IN ('flow_step_viewed', 'flow_step_completed', 'flow_abandoned')
), medians AS (
    SELECT flow_id, step,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY (attributes ->> 'duration_ms')::bigint))::bigint AS median_ms
    FROM d
    WHERE event_name = 'flow_step_completed' AND step <> '' AND attributes ->> 'duration_ms' IS NOT NULL
    GROUP BY flow_id, step
)
INSERT INTO analytics.daily_funnel_stats (day, flow_id, step, entered, completed, abandoned, median_step_ms)
SELECT sqlc.arg(day)::date, r.flow_id, r.step, sum(r.entered), sum(r.completed), sum(r.abandoned), max(m.median_ms)
FROM rows r
LEFT JOIN medians m ON m.flow_id = r.flow_id AND m.step = r.step
GROUP BY r.flow_id, r.step;

-- name: AggregateSessions :execrows
-- One pass over the day for the three distinct counts (it was three
-- subqueries over a materialised CTE: 5.6 s against 4.0 s at a million
-- events, 29F scalability check); the session lengths come from the
-- session_ended rows only, through the (event_name, received_at) index.
WITH ended AS (
    SELECT (attributes ->> 'duration_ms')::bigint AS ms
    FROM analytics.events
    WHERE received_day BETWEEN sqlc.arg(day)::date - 1 AND sqlc.arg(day)::date
      AND received_at >= (sqlc.arg(day)::date)::timestamp AT TIME ZONE 'Asia/Colombo'
      AND received_at < (sqlc.arg(day)::date + 1)::timestamp AT TIME ZONE 'Asia/Colombo'
      AND source = 'app' AND event_name = 'session_ended' AND attributes ->> 'duration_ms' IS NOT NULL
), counts AS (
    SELECT count(*) AS events,
           count(DISTINCT session_id) FILTER (WHERE session_id IS NOT NULL AND session_id <> '') AS sessions,
           count(DISTINCT coalesce(user_key, install_id)) AS users,
           count(DISTINCT user_key) AS signed_in_users
    FROM analytics.events
    WHERE received_day BETWEEN sqlc.arg(day)::date - 1 AND sqlc.arg(day)::date
      AND received_at >= (sqlc.arg(day)::date)::timestamp AT TIME ZONE 'Asia/Colombo'
      AND received_at < (sqlc.arg(day)::date + 1)::timestamp AT TIME ZONE 'Asia/Colombo'
      AND source = 'app'
)
INSERT INTO analytics.daily_session_stats (day, sessions, users, signed_in_users, median_session_ms, mean_session_ms)
SELECT sqlc.arg(day)::date, c.sessions, c.users, c.signed_in_users,
       (SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY ms))::bigint FROM ended),
       (SELECT round(avg(ms))::bigint FROM ended)
FROM counts c
WHERE c.events > 0;

-- name: AggregateErrors :execrows
-- Friction by kind, screen and a low-cardinality detail.
WITH d AS (
    SELECT CASE event_name
               WHEN 'error_shown' THEN 'error'
               WHEN 'api_error' THEN 'api_error'
               WHEN 'request_timeout' THEN 'timeout'
               WHEN 'rage_tap' THEN 'rage_tap'
               WHEN 'long_dwell' THEN 'long_dwell'
               WHEN 'credits_insufficient_shown' THEN 'insufficient_credits'
           END AS kind,
           coalesce(screen, '') AS screen,
           CASE event_name
               WHEN 'error_shown' THEN coalesce(attributes ->> 'kind', '')
               WHEN 'api_error' THEN coalesce(attributes ->> 'route', '') || ' ' || coalesce(attributes ->> 'status_class', '')
               WHEN 'request_timeout' THEN coalesce(attributes ->> 'route', '')
               ELSE ''
           END AS detail
    FROM analytics.events
    WHERE received_day BETWEEN sqlc.arg(day)::date - 1 AND sqlc.arg(day)::date
      AND received_at >= (sqlc.arg(day)::date)::timestamp AT TIME ZONE 'Asia/Colombo'
      AND received_at < (sqlc.arg(day)::date + 1)::timestamp AT TIME ZONE 'Asia/Colombo'
      AND event_name IN ('error_shown', 'api_error', 'request_timeout', 'rage_tap', 'long_dwell', 'credits_insufficient_shown')
)
INSERT INTO analytics.daily_error_stats (day, kind, screen, detail, count)
SELECT sqlc.arg(day)::date, kind, screen, detail, count(*)
FROM d
GROUP BY kind, screen, detail;

-- name: AggregateCredits :execrows
-- Credits and purchases from the server's own events.
INSERT INTO analytics.daily_credit_stats (day, event_name, detail, events, users, credits)
SELECT sqlc.arg(day)::date, event_name,
       coalesce(attributes ->> 'reason', attributes ->> 'product_id', ''),
       count(*), count(DISTINCT user_key),
       coalesce(sum((attributes ->> 'credits')::bigint), 0)::bigint
FROM analytics.events
WHERE received_day BETWEEN sqlc.arg(day)::date - 1 AND sqlc.arg(day)::date
      AND received_at >= (sqlc.arg(day)::date)::timestamp AT TIME ZONE 'Asia/Colombo'
      AND received_at < (sqlc.arg(day)::date + 1)::timestamp AT TIME ZONE 'Asia/Colombo'
  AND event_name IN ('credits_granted', 'credits_spent', 'credits_refunded', 'credits_expired', 'credits_revoked',
                     'purchase_verified', 'credits_insufficient_shown')
GROUP BY event_name, coalesce(attributes ->> 'reason', attributes ->> 'product_id', '');

-- name: UpsertFirstSeen :execrows
INSERT INTO analytics.user_first_seen (user_key, first_day)
SELECT DISTINCT user_key, sqlc.arg(day)::date
FROM analytics.events
WHERE received_day BETWEEN sqlc.arg(day)::date - 1 AND sqlc.arg(day)::date
      AND received_at >= (sqlc.arg(day)::date)::timestamp AT TIME ZONE 'Asia/Colombo'
      AND received_at < (sqlc.arg(day)::date + 1)::timestamp AT TIME ZONE 'Asia/Colombo' AND user_key IS NOT NULL
ON CONFLICT (user_key) DO UPDATE SET first_day = LEAST(analytics.user_first_seen.first_day, EXCLUDED.first_day);

-- name: InsertOptOut :exec
INSERT INTO analytics.opt_outs (user_key) VALUES (sqlc.arg(user_key)) ON CONFLICT (user_key) DO NOTHING;

-- name: DeleteOptOut :exec
DELETE FROM analytics.opt_outs WHERE user_key = sqlc.arg(user_key);

-- name: DeleteEventsByUserKey :execrows
DELETE FROM analytics.events WHERE user_key = sqlc.arg(user_key);

-- name: DeleteFirstSeen :exec
DELETE FROM analytics.user_first_seen WHERE user_key = sqlc.arg(user_key);

-- name: AggregateAbandons :execrows
-- Abandoned flows by the step they stopped at and the reason.
INSERT INTO analytics.daily_abandon_stats (day, flow_id, step, reason, count)
SELECT sqlc.arg(day)::date, flow_id, coalesce(flow_step, ''), coalesce(attributes ->> 'reason', ''), count(*)
FROM analytics.events
WHERE received_day BETWEEN sqlc.arg(day)::date - 1 AND sqlc.arg(day)::date
      AND received_at >= (sqlc.arg(day)::date)::timestamp AT TIME ZONE 'Asia/Colombo'
      AND received_at < (sqlc.arg(day)::date + 1)::timestamp AT TIME ZONE 'Asia/Colombo'
  AND event_name = 'flow_abandoned' AND flow_id IS NOT NULL AND flow_id <> ''
GROUP BY flow_id, coalesce(flow_step, ''), coalesce(attributes ->> 'reason', '');

-- name: AggregateCreditBands :execrows
-- Credits spent by price band.
INSERT INTO analytics.daily_credit_band_stats (day, band, events, credits)
SELECT sqlc.arg(day)::date,
       CASE WHEN c <= 10 THEN '1-10' WHEN c <= 20 THEN '11-20' WHEN c <= 50 THEN '21-50' ELSE '51+' END,
       count(*), sum(c)
FROM (
    SELECT (attributes ->> 'credits')::bigint AS c
    FROM analytics.events
    WHERE received_day BETWEEN sqlc.arg(day)::date - 1 AND sqlc.arg(day)::date
      AND received_at >= (sqlc.arg(day)::date)::timestamp AT TIME ZONE 'Asia/Colombo'
      AND received_at < (sqlc.arg(day)::date + 1)::timestamp AT TIME ZONE 'Asia/Colombo'
      AND event_name = 'credits_spent' AND attributes ->> 'credits' IS NOT NULL
) spent
GROUP BY 2;

-- name: AggregateInsufficientThenPurchase :execrows
-- Accounts shown "not enough credits" that verified a purchase later the
-- same day: whether the prompt leads to a purchase.
WITH d AS (
    SELECT event_name, user_key, received_at
    FROM analytics.events
    WHERE received_day BETWEEN sqlc.arg(day)::date - 1 AND sqlc.arg(day)::date
      AND received_at >= (sqlc.arg(day)::date)::timestamp AT TIME ZONE 'Asia/Colombo'
      AND received_at < (sqlc.arg(day)::date + 1)::timestamp AT TIME ZONE 'Asia/Colombo'
      AND user_key IS NOT NULL AND event_name IN ('credits_insufficient_shown', 'purchase_verified')
), converted AS (
    SELECT DISTINCT i.user_key
    FROM d i JOIN d p ON p.user_key = i.user_key AND p.event_name = 'purchase_verified' AND p.received_at >= i.received_at
    WHERE i.event_name = 'credits_insufficient_shown'
)
INSERT INTO analytics.daily_credit_stats (day, event_name, detail, events, users, credits)
SELECT sqlc.arg(day)::date, 'insufficient_then_purchase', '', count(*), count(*), 0
FROM converted
HAVING count(*) > 0;

-- name: AggregateActivity :execrows
-- The accounts active on the day.
INSERT INTO analytics.user_activity_days (day, user_key)
SELECT DISTINCT sqlc.arg(day)::date, user_key
FROM analytics.events
WHERE received_day BETWEEN sqlc.arg(day)::date - 1 AND sqlc.arg(day)::date
      AND received_at >= (sqlc.arg(day)::date)::timestamp AT TIME ZONE 'Asia/Colombo'
      AND received_at < (sqlc.arg(day)::date + 1)::timestamp AT TIME ZONE 'Asia/Colombo'
  AND user_key IS NOT NULL
ON CONFLICT (day, user_key) DO NOTHING;

-- name: DeleteAbandonStats :exec
DELETE FROM analytics.daily_abandon_stats WHERE day = sqlc.arg(day)::date;

-- name: DeleteCreditBandStats :exec
DELETE FROM analytics.daily_credit_band_stats WHERE day = sqlc.arg(day)::date;

-- name: DeleteActivity :exec
DELETE FROM analytics.user_activity_days WHERE day = sqlc.arg(day)::date;

-- name: DeleteActivityByUserKey :exec
DELETE FROM analytics.user_activity_days WHERE user_key = sqlc.arg(user_key);

-- name: DeleteActivityBefore :execrows
-- The 120-day retention of the activity table.
DELETE FROM analytics.user_activity_days WHERE day < sqlc.arg(before)::date;
