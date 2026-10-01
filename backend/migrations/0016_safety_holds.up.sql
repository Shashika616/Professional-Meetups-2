-- Safety holds (2026-09-28): the one thing kept, briefly, after an account
-- is deleted.
--
-- # WHAT AND WHY
--
-- When someone deletes their account, everything personal about them is
-- deleted (see the auth repository's Delete and the meetup module's
-- PurgeUser). The single exception is an account that has triggered SOS.
-- For those, a minimal record is held for 90 days and then purged
-- automatically, so that a person cannot erase the record of an emergency by
-- deleting their account straight afterwards while it might still be
-- investigated.
--
-- This follows the prevailing practice of comparable apps (Tinder keeps data
-- for three months after closure "to investigate unlawful or harmful
-- conduct") and sits within the exceptions data-protection law allows to the
-- right of erasure: Sri Lanka's PDPA lets a controller refuse erasure for
-- the prevention and investigation of offences and the protection of
-- persons, and Google Play expressly permits retention for security. It MUST
-- be disclosed in the privacy policy, with its purpose and duration; both
-- stores require that.
--
-- # WHAT IS IN IT, AND WHAT IS NOT
--
-- Only what an investigation would need to know who it was and what
-- happened: name, legal name, verified phone and email, and the SOS events
-- themselves. Not their meetups, contacts, photo, location history or
-- anything else. The events are copied in as JSON so the hold is
-- self-contained and the live sos_events rows can be deleted with the rest
-- of the account.
--
-- An account with no SOS events gets NO row here. Holding data about
-- everyone "in case" is exactly what data-protection law forbids; the hold
-- exists only where there is a reason for it.
--
-- # ACCESS
--
-- No API reads this table. It is for a documented, manual investigation
-- process only, and is purged by the auth module's sweeper once purge_after
-- passes.
CREATE TABLE auth.safety_holds (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- The deleted account's id. Not a foreign key: the account no longer exists.
  deleted_user_id UUID NOT NULL,
  full_name       TEXT NOT NULL,
  legal_name      TEXT,
  phone_number    TEXT,
  personal_email  TEXT,
  -- [{context_message, latitude, longitude, triggered_at, contacts_notified}]
  sos_events      JSONB NOT NULL,
  held_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  purge_after     TIMESTAMPTZ NOT NULL
);

-- The sweeper's only access path: rows whose hold has expired.
CREATE INDEX idx_safety_holds_purge_after ON auth.safety_holds (purge_after);
