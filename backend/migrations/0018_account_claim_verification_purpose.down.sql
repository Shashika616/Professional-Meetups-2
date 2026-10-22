-- Deliberately a no-op, with a reason rather than an apology.
--
-- Postgres has no DROP VALUE for an enum. Removing 'account_claim' means
-- building a replacement type, repointing auth.verification_codes.purpose
-- at it, and dropping the old one — which fails outright if any row still
-- carries the value, and that is a live OTP someone is in the middle of
-- typing. An unused enum value costs nothing: no storage, no index, no
-- behaviour. Rolling the code back stops minting it, which is the whole of
-- what a rollback actually needs.
--
-- Not silent about it, though, so nobody reads a clean `migrate down` as
-- proof the type went back to five values.
DO $$ BEGIN
  RAISE NOTICE 'auth.verification_purpose keeps its account_claim value: Postgres cannot drop an enum value, and an unused one is inert. See the .up.sql for why this is safe.';
END $$;
