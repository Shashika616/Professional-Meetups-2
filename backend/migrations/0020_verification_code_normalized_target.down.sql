-- Reverses 0020. The old index is rebuilt before the new one is dropped,
-- mirroring the up migration so neither direction leaves the table
-- unprotected.
--
-- Rebuilding (purpose, target) can fail where 0020's normalisation merged
-- two spellings into one row and the application has since written both
-- spellings again — in practice it cannot, because the service normalises
-- before writing, so every live row is already in normalised form and the
-- two indexes agree. If it ever does fail, the 23505 names the duplicate
-- and the fix is to delete the older row; there is nothing to preserve in
-- an unexpired OTP.

CREATE UNIQUE INDEX IF NOT EXISTS idx_verification_codes_signup_target
    ON auth.verification_codes (purpose, target) WHERE user_id IS NULL;

DROP INDEX IF EXISTS auth.idx_verification_codes_signup_target_normalized;

ALTER TABLE auth.verification_codes DROP COLUMN IF EXISTS target_normalized;
