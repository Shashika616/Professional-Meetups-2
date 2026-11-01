-- billing.ledger_entries is append-only (ADR-010). 0026's trigger covers
-- UPDATE and DELETE row by row; TRUNCATE fires no row triggers, so it could
-- empty the ledger in one statement. This closes that (29A review fix 3).
--
-- Tests no longer truncate the ledger: every test uses fresh user ids and
-- scopes its assertions to them.
DROP TRIGGER IF EXISTS ledger_entries_no_truncate ON billing.ledger_entries;
CREATE TRIGGER ledger_entries_no_truncate
    BEFORE TRUNCATE ON billing.ledger_entries
    FOR EACH STATEMENT EXECUTE FUNCTION billing.reject_ledger_change();
