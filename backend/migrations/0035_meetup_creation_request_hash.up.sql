-- Plan 30B (review N1-B6): an Idempotency-Key reused with different
-- parameters used to return the first meetup with a 200, as though the new
-- request had been made. The hash of what was asked is kept beside the key,
-- so a replay can be told from a different request (409). Rows created
-- before this have no hash and keep today's behaviour.
ALTER TABLE meetup.meetups ADD COLUMN creation_request_hash TEXT
    CHECK (creation_request_hash IS NULL OR length(creation_request_hash) = 64);
