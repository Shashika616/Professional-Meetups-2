ALTER TABLE meetup.meetups_completed_outbox RESET (
  autovacuum_vacuum_scale_factor, autovacuum_vacuum_threshold,
  autovacuum_analyze_scale_factor, autovacuum_analyze_threshold);
ALTER TABLE meetup.notification_outbox RESET (
  autovacuum_vacuum_scale_factor, autovacuum_vacuum_threshold,
  autovacuum_analyze_scale_factor, autovacuum_analyze_threshold);
ALTER TABLE meetup.meetup_requests RESET (
  autovacuum_vacuum_scale_factor, autovacuum_vacuum_threshold,
  autovacuum_analyze_scale_factor, autovacuum_analyze_threshold);
DROP INDEX IF EXISTS meetup.idx_meetups_cancelled_recent;
CREATE INDEX IF NOT EXISTS idx_meetup_requests_requester ON meetup.meetup_requests (requester_id);
DROP INDEX IF EXISTS meetup.idx_meetup_requests_requester_history;
