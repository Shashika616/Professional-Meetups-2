-- The profile's "MEETUPS" figure (frontend `profile_page.dart`'s stats row),
-- which until now was a hardcoded literal 12 shown to every account
-- including brand-new ones.
--
-- These two columns are a READ-ONLY CACHE on the auth side, exactly like
-- rating_average/rating_count above them: the meetup module owns the facts
-- (meetup.meetups + meetup.meetup_requests), computes the count from them,
-- and publishes it; this module's consumer is the only writer. Nothing in
-- auth's own RPCs ever writes these. That is ADR-001 §3 — the schema
-- boundary is kept and the cache is event-fed, rather than the profile read
-- reaching across into the meetup schema.
--
-- WHY A CACHED COUNT AND NOT A LIVE COUNT(*): GetProfile is on the hot path
-- for every app launch, the meetup tables live in another module's schema,
-- and the number only changes when a meetup completes — rarely, and at a
-- moment the meetup module already knows about. The same three reasons the
-- rating aggregate is cached here.

-- NOT NULL DEFAULT 0, so every account that exists today starts at a
-- truthful zero rather than a NULL that the UI would have to render as
-- something. No backfill: an existing user's real historical count is
-- recomputed and published the next time any meetup of theirs completes,
-- and until then 0 is the honest answer for a figure that was never
-- previously tracked. (0 is also, for the overwhelming majority of accounts
-- at this stage, the correct answer.)
ALTER TABLE auth.users
    ADD COLUMN meetups_completed INT NOT NULL DEFAULT 0;

-- The ordering guard's stored timestamp, mirroring rating_updated_at.
-- Nullable, and NULL means "no event has ever been applied", which is what
-- lets the first event through unconditionally.
--
-- This is what makes the consumer idempotent. The event carries an ABSOLUTE
-- count rather than a delta precisely so that a redelivered or out-of-order
-- event is a harmless no-op instead of double-counting a meetup — a delta
-- would have no way to tell the difference.
ALTER TABLE auth.users
    ADD COLUMN meetups_completed_updated_at TIMESTAMPTZ;
