-- Tracker #79 / review finding N-B1 (High, supersedes #58's "reported").
--
-- # WHAT WAS WRONG
--
-- meetup_requests carried UNIQUE (meetup_id, requester_id, status). That
-- reads as "one request per person per meetup per state", which sounds
-- right and is not: it makes the STATE part of the key, so it permits two
-- live rows in different states and forbids two dead rows in the same
-- one.
--
-- Both halves broke real flows. A requester rejected once and
-- re-requesting holds a 'rejected' row and a 'pending' row at the same
-- time, and then:
--
--   * the host rejecting the new request collides with the old 'rejected'
--     row — 23505, surfaced as a 500;
--   * the final-seat accept rolls back, because auto-rejecting the other
--     pending requests collides the same way;
--   * withdrawing a second acceptance collides with the first 'withdrawn'
--     row.
--
-- The griefing path writes itself: re-request after a rejection and the
-- host can neither fill the last seat nor reject you.
--
-- # WHAT REPLACES IT
--
-- A PARTIAL unique index over the live states only. 'pending' and
-- 'accepted' are the states that hold a seat or a claim on one; everything
-- else is history and may repeat freely. The status is no longer part of
-- what is unique, so the two live rows the old key allowed are now
-- impossible, and the duplicate dead rows it forbade are now fine.
--
-- Re-request policy (plan decision D1) is enforced in the service, not
-- here: a WITHDRAWN user may request again, a REJECTED user may not. The
-- index deliberately cannot express that — it would have to include
-- 'rejected', which reintroduces exactly the collision this removes.
--
-- # ORDER MATTERS
--
-- The index is built BEFORE the old constraint is dropped, so there is no
-- instant in which the table is unprotected. A failure between the two
-- leaves the old constraint in force and an extra index that is
-- redundant but harmless.
--
-- CREATE INDEX, not CONCURRENTLY: golang-migrate wraps each migration in a
-- transaction and CONCURRENTLY cannot run inside one. The table is small
-- (requests, not events) and the lock is brief; if that ever stops being
-- true, split this into its own non-transactional migration.

CREATE UNIQUE INDEX IF NOT EXISTS uq_meetup_requests_one_live_per_user
    ON meetup.meetup_requests (meetup_id, requester_id)
    WHERE status IN ('pending', 'accepted');

ALTER TABLE meetup.meetup_requests
    DROP CONSTRAINT IF EXISTS meetup_requests_meetup_id_requester_id_status_key;
