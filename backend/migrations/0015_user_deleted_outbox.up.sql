-- The user-deleted outbox (2026-09-28): how the auth module tells everyone
-- else that an account is gone, WITHOUT calling them.
--
-- # WHY AN OUTBOX, AND WHY THIS EVENT NEEDS ONE WHEN OTHERS DO NOT
--
-- Account deletion crosses a module boundary: the meetup schema keeps its
-- own copy of a user's name and photograph (user_display_cache), their
-- location, their requests and their reviews, and no foreign key connects it
-- to auth.users — deliberately (ADR-001 §3), so the two could be separate
-- services with separate databases. That independence is the point, and it
-- means the meetup side has to be TOLD.
--
-- The auth module's other events (user-profile-updated and friends) are a
-- plain bus.Publish after the write, with a failed handler merely logged
-- (ADR-001 §4). That is fine for a profile update — the worst case is a
-- stale display name, corrected by the next edit. It is NOT fine here. A
-- lost user-deleted event would leave a deleted person's name, face and
-- location sitting in another schema forever, with a log line as the only
-- record, and nothing would ever retry it. Deletion is a legal obligation
-- (App Store 5.1.1(v), Play's data-deletion policy), so it gets guaranteed
-- delivery.
--
-- The row is written IN THE SAME TRANSACTION as the delete of auth.users.
-- Either the account is gone and the event is queued, or neither happened.
-- There is no window in which the account is deleted but nobody will ever
-- hear about it — which is the entire reason this is a table and not a
-- function call.
--
-- Shape copied from meetup.meetups_completed_outbox (0006) and driven by the
-- same generic poller (internal/platform/outbox): claim with FOR UPDATE SKIP
-- LOCKED, exponential backoff, dead-letter after the retry ceiling, keep
-- dead letters as evidence. One row per deleted account.
CREATE TABLE auth.user_deleted_outbox (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- The deleted account. NOT a foreign key, and it cannot be one: the whole
  -- point of the row is that it outlives the auth.users row it describes.
  user_id          UUID NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  processed_at     TIMESTAMPTZ,
  attempts         INT NOT NULL DEFAULT 0,
  next_attempt_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  dead_lettered_at TIMESTAMPTZ,
  last_error       TEXT
);

-- The poller's claim query. Partial, so it stays small however many rows
-- have been processed: it only ever holds work that is still due.
CREATE INDEX idx_user_deleted_outbox_claimable
  ON auth.user_deleted_outbox (next_attempt_at)
  WHERE processed_at IS NULL AND dead_lettered_at IS NULL;

-- Retention sweeps, one per terminal state (same split as 0006).
CREATE INDEX idx_user_deleted_outbox_retention
  ON auth.user_deleted_outbox (processed_at)
  WHERE processed_at IS NOT NULL;

CREATE INDEX idx_user_deleted_outbox_dead_lettered
  ON auth.user_deleted_outbox (dead_lettered_at)
  WHERE dead_lettered_at IS NOT NULL;
