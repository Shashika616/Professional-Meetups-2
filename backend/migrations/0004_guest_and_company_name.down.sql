-- Reverses 0004_guest_and_company_name.up.sql.
--
-- Dropping is_guest silently converts every guest account into a Level 1
-- account on the next trust-level recompute (computeTrustLevel's guest branch
-- disappears with the column). That is the only sensible reversal — there is
-- nowhere else to record guest-ness — but it is a real data-meaning change,
-- not a clean undo, so it is called out here rather than discovered later.
ALTER TABLE auth.users
    DROP COLUMN IF EXISTS company_name;

ALTER TABLE auth.users
    DROP COLUMN IF EXISTS is_guest;
