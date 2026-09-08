-- Guest login + trust-level 0–3 redesign (ADR-002 §1, canonical product
-- decision ADR-033 in the sibling repo).
--
-- Two columns, both on auth.users, both additive. No backfill and no data
-- migration: every existing row picks up is_guest = false from the DEFAULT,
-- which is exactly right — no account created before this migration was ever
-- a guest, and none should retroactively become one.

-- is_guest is the ONLY thing separating trust Level 0 from Level 1 after this
-- change (see computeTrustLevel in internal/modules/auth/trustlevel.go). The
-- old floor — "no LinkedIn linked → Level 0" — is gone, so every account made
-- through any of the four real signup paths lands at Level 1 immediately.
--
-- NOT NULL with a DEFAULT rather than nullable: a NULL here would be a third
-- state with no meaning ("might be a guest"), and every read of it feeds a
-- trust-level decision that has to be unambiguous.
ALTER TABLE auth.users
    ADD COLUMN is_guest BOOLEAN NOT NULL DEFAULT false;

-- company_name is the free-text organisation name, newly required for Level 3
-- alongside the already-existing verified work email (ADR-002 §2). Distinct
-- from company_domain, which is DERIVED from the verified address and is not
-- a substitute: "Acme Corporation" is not recoverable from "acme.co.uk".
--
-- Nullable with no default: absent genuinely means "not provided yet", and
-- Level 3 tests it for emptiness. It is written in the same statement as
-- work_email_verified (UpdateUserWorkEmailVerified) so the two halves of the
-- Level 3 condition can never disagree — see that query's comment.
ALTER TABLE auth.users
    ADD COLUMN company_name TEXT;
