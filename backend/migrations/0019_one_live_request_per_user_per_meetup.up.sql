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
-- # EXISTING DUPLICATES (tracker #101, review N1-B2)
--
-- The old key allowed one 'pending' AND one 'accepted' row for the same
-- person on the same meetup, and that is exactly the pair the new index
-- refuses: on such data CREATE UNIQUE INDEX fails with 23505 and the
-- migration stops. The accepted row is the one that holds a seat, so it is
-- kept, and the extra pending row is marked 'withdrawn' (resolved now, no
-- note). Nothing else is touched. The runbook's pre-flight query (§3)
-- counts these rows before deploying.
--
-- # ORDER MATTERS
--
-- This file runs as one transaction (golang-migrate sends it as a single
-- multi-statement Exec), so no other session ever sees the table between
-- the old constraint and the new index. Within it:
--
--   1. Lock the table against writes, so no new request arrives between
--      the cleanup and the index.
--   2. Drop the old constraint FIRST. It must be gone before the cleanup:
--      turning the pending row into 'withdrawn' would collide with it
--      whenever the same person had already withdrawn once before.
--   3. Clean up, then build the index.
--
-- CREATE INDEX, not CONCURRENTLY: CONCURRENTLY cannot run inside a
-- transaction. The table is small (requests, not events) and the lock is
-- brief; if that ever stops being true, split this into its own
-- non-transactional migration.

LOCK TABLE meetup.meetup_requests IN SHARE ROW EXCLUSIVE MODE;

ALTER TABLE meetup.meetup_requests
    DROP CONSTRAINT IF EXISTS meetup_requests_meetup_id_requester_id_status_key;

UPDATE meetup.meetup_requests p
   SET status = 'withdrawn', resolved_at = COALESCE(p.resolved_at, now())
 WHERE p.status = 'pending'
   AND EXISTS (
        SELECT 1 FROM meetup.meetup_requests a
         WHERE a.meetup_id = p.meetup_id
           AND a.requester_id = p.requester_id
           AND a.status = 'accepted');

CREATE UNIQUE INDEX IF NOT EXISTS uq_meetup_requests_one_live_per_user
    ON meetup.meetup_requests (meetup_id, requester_id)
    WHERE status IN ('pending', 'accepted');
