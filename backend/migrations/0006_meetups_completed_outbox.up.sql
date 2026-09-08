-- Moves the meetups-completed recompute off the closing transaction's
-- critical path (docs/plans/06-async-meetups-completed-recompute.md).
--
-- WHY THIS TABLE EXISTS. Closing a meetup used to run
-- RecomputeMeetupsCompletedForParticipants inline, before commit — a
-- correlated subquery that re-derives each participant's ENTIRE lifetime
-- completed count from scratch. Cost scales with (distinct participants in
-- the batch) x (each one's full history), and it held the closing
-- transaction's locks for the duration. A host with thousands of past
-- meetups had their whole history recounted every time any one meetup
-- closed, while other writes to meetup.meetups / meetup.meetup_requests
-- queued behind it. The auto-close sweep closes up to 100 meetups per tick,
-- all in one transaction.
--
-- Same fix as migration 0003 applied to a second problem: write a small,
-- durable record of INTENT in the business transaction (cheap, atomic with
-- the completion), and let a poller do the expensive part afterwards. The
-- machinery in internal/platform/outbox is already generic — Row.Payload is
-- opaque to it — so only this table and a second Store implementation are
-- new.
--
-- This is a friendlier outbox consumer than notifications were. The
-- recompute always re-derives the true current total from authoritative
-- data, never a delta, and the auth-side cache write is guarded on the count
-- itself, so a duplicate delivery is a complete no-op rather than a "minor
-- annoyance we accept". None of 0003's at-least-once caveats bite here.
CREATE TABLE meetup.meetups_completed_outbox (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- The meetups that just completed. ONE ROW PER COMPLETION BATCH, not per
  -- meetup: the recompute query already batches efficiently across ids
  -- (participants are de-duplicated by its UNION), so splitting into
  -- per-meetup rows would multiply claim/poll overhead for no gain, and
  -- would recount a shared participant once per meetup instead of once.
  meetup_ids       UUID[] NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Same convention as notification_outbox: processed_at IS NULL is the
  -- whole "has this been done" question, no status enum to keep consistent,
  -- because success is the only thing that ever writes it.
  processed_at     TIMESTAMPTZ,
  attempts         INT NOT NULL DEFAULT 0,
  next_attempt_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  dead_lettered_at TIMESTAMPTZ,
  last_error       TEXT
);

-- Partial, for the same reason as idx_notification_outbox_claimable: only
-- pending rows are ever in it, so claim latency tracks the size of the
-- PENDING set rather than total history. Ordered by next_attempt_at to match
-- the claim query's ORDER BY exactly — ordering by created_at would force an
-- unindexed sort, and next_attempt_at is the more correct priority anyway
-- (a backing-off row should rank behind fresh ones).
CREATE INDEX idx_meetups_completed_outbox_claimable
  ON meetup.meetups_completed_outbox (next_attempt_at)
  WHERE processed_at IS NULL AND dead_lettered_at IS NULL;

-- Retention indexes, mirroring 0003's. Each covers exactly the predicate its
-- retention DELETE uses, so the hourly sweep never scans the live pending
-- set to find terminal rows.
CREATE INDEX idx_meetups_completed_outbox_retention
  ON meetup.meetups_completed_outbox (processed_at)
  WHERE processed_at IS NOT NULL;

CREATE INDEX idx_meetups_completed_outbox_dead_lettered
  ON meetup.meetups_completed_outbox (dead_lettered_at)
  WHERE dead_lettered_at IS NOT NULL;
