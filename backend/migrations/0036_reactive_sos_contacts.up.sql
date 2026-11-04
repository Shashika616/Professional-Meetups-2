-- Plan 30C (ADR-013): trusted contacts are a name and a phone number, nothing
-- else, and they hear from us only when the user presses SOS.
--
-- # CONTACTS
--
-- * Contact email goes (nulled, then dropped). An email-only contact from
--   before the phone rule can no longer be reached, so the row goes too.
-- * phone_number is stored in E.164 and phone_normalized holds the same
--   value for the uniqueness rule. A local Sri Lankan 0XXXXXXXXX becomes
--   +94XXXXXXXXX, the same rule the service applies. A number that cannot
--   be normalised is left as it is: it stays visible so the user can fix it.
-- * The same number twice for one user keeps the oldest row.
-- * Consent is retired: the pending table goes, so every contact is active,
--   including ones that never answered their invitation (decision D5, D6).
--   The invitation log goes with it, since nothing is sent on add.
-- * An account with 3 contacts keeps all 3; SOS alerts the 2 oldest and the
--   app asks the user to remove one (D5).
--
-- # SOS EVENTS
--
-- location_source and location_captured_at say which step of the location
-- chain the event's coordinates came from. They are deleted with the row by
-- the 90-day sweep, and copied into a safety hold with the rest.
--
-- # LIVE LOCATION
--
-- meetup.safety_state.live_location_opt_in was a boolean nothing read.
--
-- Pre-flight: runbook §3a. Until the new revision serves, the old one cannot
-- read contacts, so run this immediately before the deploy.

DELETE FROM auth.trusted_contacts WHERE phone_number IS NULL OR btrim(phone_number) = '';
UPDATE auth.trusted_contacts SET email = NULL;

ALTER TABLE auth.trusted_contacts DROP COLUMN email;
ALTER TABLE auth.trusted_contacts ADD COLUMN phone_normalized TEXT;

UPDATE auth.trusted_contacts
   SET phone_normalized = CASE
        WHEN regexp_replace(phone_number, '[\s().-]', '', 'g') ~ '^0[0-9]{9}$'
            THEN '+94' || substr(regexp_replace(phone_number, '[\s().-]', '', 'g'), 2)
        ELSE regexp_replace(phone_number, '[\s().-]', '', 'g')
       END;
UPDATE auth.trusted_contacts SET phone_number = phone_normalized;

DELETE FROM auth.trusted_contacts c
 USING auth.trusted_contacts older
 WHERE c.user_id = older.user_id
   AND c.phone_normalized = older.phone_normalized
   AND (older.created_at, older.id) < (c.created_at, c.id);

ALTER TABLE auth.trusted_contacts
    ALTER COLUMN phone_number SET NOT NULL,
    ALTER COLUMN phone_normalized SET NOT NULL;
CREATE UNIQUE INDEX uq_trusted_contacts_user_phone
    ON auth.trusted_contacts (user_id, phone_normalized);

DROP TABLE auth.pending_trusted_contacts;
DROP TABLE auth.contact_invites_sent;

ALTER TABLE auth.sos_events
    ADD COLUMN location_source TEXT,
    ADD COLUMN location_captured_at TIMESTAMPTZ;

ALTER TABLE meetup.safety_state DROP COLUMN live_location_opt_in;
