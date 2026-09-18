-- Indexes for FindScheduleConflict (gap #42, Plan 20 Fix 1).
--
-- The query used to scope "the caller's own meetups" with an OR across a
-- joined relation, which left the planner a range scan over every live
-- meetup on the platform. It is now two branches unioned, and each branch
-- gets an index shaped like its predicate.

-- Lets FindScheduleConflict's "meetups I host" branch seek directly to one
-- user's live meetups instead of scanning every live meetup on the
-- platform. Partial + covers the exact predicate shape that branch uses.
CREATE INDEX IF NOT EXISTS idx_meetups_host_live
  ON meetup.meetups (host_user_id, window_start, window_end)
  WHERE status IN ('open', 'full');

-- Same idea for the "meetups I've requested" branch: narrows
-- meetup_requests to one user's still-live requests before the join to
-- meetups, instead of the requester-history index needing a post-filter on
-- status for every historical row it returns.
CREATE INDEX IF NOT EXISTS idx_meetup_requests_requester_active
  ON meetup.meetup_requests (requester_id)
  WHERE status IN ('pending', 'accepted');
