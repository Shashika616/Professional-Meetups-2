DROP INDEX IF EXISTS auth.idx_sos_events_user_triggered;
DROP INDEX IF EXISTS auth.uq_sos_events_user_client_request;
ALTER TABLE auth.sos_events
    DROP COLUMN IF EXISTS completed_at,
    DROP COLUMN IF EXISTS client_request_id;
