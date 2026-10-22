-- A trusted contact agrees before they can be alerted (#80, decision D2).
--
-- Until now anyone could type any phone number in as a "trusted contact"
-- and have the service text it. New contacts start pending: they get one
-- SMS with a link, and only once they confirm through it do SOS alerts and
-- meetup shares reach them.
--
-- WHY A SEPARATE TABLE, NOT COLUMNS ON trusted_contacts: the revision that
-- is serving when this runs reads trusted_contacts with SELECT * and
-- RETURNING *, and sqlc scans a fixed number of columns. Adding columns
-- would break adding and listing contacts for the minutes between this
-- migration and the new revision, and for good on any rollback. A row here
-- changes nothing the old code reads.
--
-- Presence means NOT YET CONFIRMED; confirming deletes the row. So every
-- contact that exists today, having no row here, is confirmed — the D2
-- grandfathering needs no backfill. Never sweep this table by expiry: an
-- expired invite whose row vanished would read as confirmed.
CREATE TABLE IF NOT EXISTS auth.pending_trusted_contacts (
    contact_id UUID PRIMARY KEY
        REFERENCES auth.trusted_contacts (id) ON DELETE CASCADE,
    -- sha256 of the single-use token in the link; the token itself is
    -- never stored.
    token_hash TEXT NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL
);

-- Every invitation SMS sent, for the daily caps. Without this, removing and
-- re-adding a contact would be an unlimited way to text a stranger at this
-- project's expense. Rows older than a week are swept: the caps look back
-- one day.
CREATE TABLE IF NOT EXISTS auth.contact_invites_sent (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID NOT NULL,
    -- sha256 of the normalised number, so the per-number cap works across
    -- users without this log holding the numbers themselves.
    phone_hash TEXT NOT NULL,
    sent_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_contact_invites_sent_user
    ON auth.contact_invites_sent (user_id, sent_at);
CREATE INDEX IF NOT EXISTS idx_contact_invites_sent_phone
    ON auth.contact_invites_sent (phone_hash, sent_at);
CREATE INDEX IF NOT EXISTS idx_contact_invites_sent_at
    ON auth.contact_invites_sent (sent_at);
