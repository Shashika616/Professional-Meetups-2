-- Plan 30B: two small counter tables in Postgres, so a limit holds across
-- every Cloud Run instance instead of per process.
--
-- # auth.otp_budgets (tracker #106, review N1-A1)
--
-- Per target and purpose, per Asia/Colombo day: how many codes were sent
-- and how many guesses failed. Requesting a new code does NOT reset it, so
-- "a new code every minute, five guesses each" no longer adds up to
-- thousands of guesses a day against one passwordless account, and one
-- address cannot be used to exhaust the mail quota. Allowlisted test
-- addresses (TESTING-NOTES.md) never get a row.
--
-- target_hash is SHA-256 of the normalised e-mail or phone number, not the
-- address itself: this table must not become another copy of who signed in.
--
-- # ops.rate_counters (tracker #81)
--
-- A fixed-window counter shared by every instance, for the limits that
-- matter most (OTP, SOS, trusted contacts, meetup share, photo upload). The
-- key is hashed for the same reason. expires_at lets a sweep delete
-- finished windows.
CREATE TABLE auth.otp_budgets (
    target_hash    BYTEA   NOT NULL,
    purpose        TEXT    NOT NULL,
    day            DATE    NOT NULL,
    sends          INTEGER NOT NULL DEFAULT 0 CHECK (sends >= 0),
    failed_guesses INTEGER NOT NULL DEFAULT 0 CHECK (failed_guesses >= 0),
    PRIMARY KEY (target_hash, purpose, day)
);
CREATE INDEX idx_otp_budgets_day ON auth.otp_budgets (day);

CREATE TABLE ops.rate_counters (
    key_hash     BYTEA       NOT NULL,
    window_start TIMESTAMPTZ NOT NULL,
    count        INTEGER     NOT NULL CHECK (count >= 0),
    expires_at   TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (key_hash, window_start)
);
CREATE INDEX idx_rate_counters_expires ON ops.rate_counters (expires_at);
