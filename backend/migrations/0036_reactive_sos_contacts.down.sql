-- Restores the columns and tables. Their DATA is not restored: contact
-- emails, pending invitations, the invitation log and opt-in flags are gone,
-- so every contact stays active and no contact has an email.
ALTER TABLE meetup.safety_state ADD COLUMN live_location_opt_in BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE auth.sos_events DROP COLUMN location_captured_at, DROP COLUMN location_source;

CREATE TABLE auth.pending_trusted_contacts (
    contact_id UUID PRIMARY KEY
        REFERENCES auth.trusted_contacts (id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE TABLE auth.contact_invites_sent (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID NOT NULL,
    phone_hash TEXT NOT NULL,
    sent_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_contact_invites_sent_user ON auth.contact_invites_sent (user_id, sent_at);
CREATE INDEX idx_contact_invites_sent_phone ON auth.contact_invites_sent (phone_hash, sent_at);
CREATE INDEX idx_contact_invites_sent_at ON auth.contact_invites_sent (sent_at);

DROP INDEX auth.uq_trusted_contacts_user_phone;
ALTER TABLE auth.trusted_contacts
    ALTER COLUMN phone_number DROP NOT NULL,
    DROP COLUMN phone_normalized,
    ADD COLUMN email TEXT,
    ADD CONSTRAINT trusted_contacts_check CHECK (phone_number IS NOT NULL OR email IS NOT NULL);
