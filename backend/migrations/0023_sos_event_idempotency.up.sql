-- One SOS, one alert, however many times the request is retried.
--
-- The app retries an SOS once when the first attempt times out (#78). When
-- the first attempt had in fact reached the server and was still texting
-- contacts, the retry texted them all again: the same emergency, twice.
-- The client now sends one client_request_id for both attempts, and this
-- index lets exactly one of them claim the event; the other reads the
-- outcome instead of re-sending.
--
-- Old app builds send no id. Their rows have it NULL, which the partial
-- index ignores, so they behave exactly as before.
--
-- Safe against the revision already serving: nothing reads this table with
-- SELECT * or RETURNING *, so new columns do not change any old query.
ALTER TABLE auth.sos_events
    ADD COLUMN IF NOT EXISTS client_request_id TEXT,
    ADD COLUMN IF NOT EXISTS completed_at TIMESTAMPTZ;

-- Every row that exists today is an alert that already finished.
UPDATE auth.sos_events SET completed_at = triggered_at WHERE completed_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_sos_events_user_client_request
    ON auth.sos_events (user_id, client_request_id)
    WHERE client_request_id IS NOT NULL;

-- The per-user daily cap counts a user's alerts over the last 24 hours.
CREATE INDEX IF NOT EXISTS idx_sos_events_user_triggered
    ON auth.sos_events (user_id, triggered_at);
