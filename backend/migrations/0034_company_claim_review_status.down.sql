DROP INDEX IF EXISTS auth.idx_unverified_company_claims_pending;
ALTER TABLE auth.unverified_company_claims DROP COLUMN IF EXISTS reviewed_at, DROP COLUMN IF EXISTS status;
