-- Dropping the pending table makes every pending contact read as confirmed
-- to code that no longer knows about consent, which is exactly the
-- pre-0024 behaviour that code expects.
DROP TABLE IF EXISTS auth.contact_invites_sent;
DROP TABLE IF EXISTS auth.pending_trusted_contacts;
