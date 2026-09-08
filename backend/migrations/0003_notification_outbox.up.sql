-- Durable delivery for push notifications (ADR-001's "Correction
-- (2026-09-04, durable notification delivery)", docs/plans/03-hardening-pass.md
-- §F).
--
-- WHY THIS TABLE EXISTS, given ADR-001 §4 deliberately removed the source's
-- outbox machinery: every OTHER event in this system feeds an idempotent
-- cache upsert, so losing one in the commit-then-crash window leaves a cache
-- briefly stale and it self-heals on the next event touching that row (with
-- cmd/backfill-user-*-cache as the backstop). push-notification-requested
-- has no such recovery path — nothing will ever re-send "the host accepted
-- your request" — and it is also the only topic that requires a real
-- third-party network call. That combination (user-facing, one-shot, no
-- self-heal, network-coupled) is the profile durability machinery exists
-- for. Scoped to this one topic on purpose; §4 stands for everything else.
--
-- Lives in the meetup schema because meetup owns every publisher of this
-- topic (ADR-001 §3 — a table belongs to the module that writes it). The
-- notification module reads it through internal/platform/outbox and owns no
-- schema of its own, exactly like the source's notification-dispatch service.
CREATE TABLE meetup.notification_outbox (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Resolved FCM tokens, not a user id: the notification module has no
  -- database and cannot answer "which devices does this user have", so the
  -- publisher resolves them inside the same transaction that writes this row.
  fcm_tokens       TEXT[] NOT NULL,
  title            TEXT NOT NULL,
  body             TEXT NOT NULL,
  data             JSONB NOT NULL DEFAULT '{}',
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- processed_at IS NULL is the entire "was this delivered" question. No
  -- status enum: nothing writes this column except success, so "not yet
  -- delivered" is the ABSENCE of a write rather than a value every failure
  -- path has to remember to set correctly.
  processed_at     TIMESTAMPTZ,
  attempts         INT NOT NULL DEFAULT 0,
  -- Defaults to insertion time, which makes a fresh row immediately due and
  -- makes ORDER BY next_attempt_at close to FIFO for the common case.
  next_attempt_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  dead_lettered_at TIMESTAMPTZ,
  last_error       TEXT
);

-- PARTIAL on purpose, and it is what keeps the claim query cheap regardless
-- of table size: only currently-pending rows are ever in this index, so a
-- million delivered rows sitting in the table do not make it any bigger —
-- they are simply not in it. Claim latency then depends on the size of the
-- PENDING set (small, if the poller keeps up), not on total history. Growth
-- from processed history is a storage/VACUUM concern, handled by the
-- retention job (§F8), not a query-latency one.
--
-- ClaimBatch must ORDER BY next_attempt_at to match this index. Ordering by
-- created_at instead would force a separate sort step that gets more
-- expensive as the pending set grows — and next_attempt_at is the more
-- correct priority anyway: a row that has failed and is backing off should
-- rank behind fresh rows rather than competing with them on original
-- insertion time.
CREATE INDEX idx_notification_outbox_claimable
  ON meetup.notification_outbox (next_attempt_at)
  WHERE processed_at IS NULL AND dead_lettered_at IS NULL;

-- Supports the retention job's two DELETE predicates (§F8). Also partial:
-- only rows that have reached a terminal state are ever candidates for
-- deletion, and pending rows have no business being scanned by it.
CREATE INDEX idx_notification_outbox_retention
  ON meetup.notification_outbox (processed_at)
  WHERE processed_at IS NOT NULL;
CREATE INDEX idx_notification_outbox_dead_lettered
  ON meetup.notification_outbox (dead_lettered_at)
  WHERE dead_lettered_at IS NOT NULL;
