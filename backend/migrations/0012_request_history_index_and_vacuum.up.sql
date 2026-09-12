-- Long-run read health for the tables that accumulate history.
--
-- Measured before this migration against 300k historical meetup_requests
-- rows (rejected/withdrawn), which is what years of use will look like:
--   accepted_count per card ....... index-only scan, 3 buffers  (already fine)
--   viewer's own request .......... unique-key lookup, 4 buffers (already fine)
--   requester history ............. 7 ms: 3,000-row index scan + sort + unique
-- The (meetup_id, status) composite from 0001 already keeps the per-meetup
-- reads off terminal rows, so no partial index is needed there. What was
-- missing is an index shaped like the requester-side query.

-- 1. Requester history. ListMeetupsRequestedByUser* selects DISTINCT ON
--    (meetup_id) ... WHERE requester_id = ? ORDER BY meetup_id, created_at
--    DESC. An index in exactly that order lets the planner walk it and emit
--    one row per meetup with no sort step, however many past requests the
--    person has. Supersedes the plain (requester_id) index, which is its
--    leading column.
CREATE INDEX IF NOT EXISTS idx_meetup_requests_requester_history
  ON meetup.meetup_requests (requester_id, meetup_id, created_at DESC);
DROP INDEX IF EXISTS meetup.idx_meetup_requests_requester;

-- 2. The cancelled branch of ListMeetupIDsAwaitingReview filters on
--    status = 'cancelled' AND cancelled_at > cutoff. Cancelled meetups are
--    a small minority of the table for ever, so a partial index keeps that
--    lookup constant-time as the table grows.
CREATE INDEX IF NOT EXISTS idx_meetups_cancelled_recent
  ON meetup.meetups (cancelled_at)
  WHERE status = 'cancelled';

-- 3. Autovacuum for the churny tables. The database default triggers a
--    vacuum at 20% dead tuples, which on a large table means millions of
--    dead rows sitting in the heap and indexes before anything is
--    reclaimed. These tables see constant UPDATE/DELETE traffic (request
--    state changes; outbox claim-and-delete), so they are vacuumed at 5%
--    dead or 200 rows, whichever comes first, and analyzed at 2% so the
--    planner's row estimates stay honest. Per-table settings only — the
--    rest of the schema keeps the defaults.
ALTER TABLE meetup.meetup_requests SET (
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_vacuum_threshold = 200,
  autovacuum_analyze_scale_factor = 0.02,
  autovacuum_analyze_threshold = 100
);
ALTER TABLE meetup.notification_outbox SET (
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_vacuum_threshold = 200,
  autovacuum_analyze_scale_factor = 0.02,
  autovacuum_analyze_threshold = 100
);
ALTER TABLE meetup.meetups_completed_outbox SET (
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_vacuum_threshold = 200,
  autovacuum_analyze_scale_factor = 0.02,
  autovacuum_analyze_threshold = 100
);
