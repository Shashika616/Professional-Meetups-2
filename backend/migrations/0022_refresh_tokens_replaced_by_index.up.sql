-- An index on the self-reference, for the expired-token sweep.
--
-- DeleteExpiredRefreshTokens now skips rows another row still points at
-- (`NOT EXISTS (SELECT 1 ... WHERE r.replaced_by = t.id)`), because the
-- FK forbids deleting them. Without an index on replaced_by that subquery
-- is a sequential scan per candidate row, on the one table in this schema
-- that grows with every login AND every refresh.
--
-- Partial: rotation sets replaced_by on the OLD row only, so in a healthy
-- table most rows are NULL (97 of 296 non-null in production on
-- 2026-10-22). Indexing only the non-null rows keeps it small and still
-- answers the subquery, which never looks for NULL.
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_replaced_by
    ON auth.refresh_tokens (replaced_by)
    WHERE replaced_by IS NOT NULL;
