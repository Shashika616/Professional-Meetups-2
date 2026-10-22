-- Tracker #82 / review finding N-A1 (Medium).
--
-- # WHAT WAS WRONG
--
-- Every OTP budget, cooldown and rate-limit bucket was keyed on the raw
-- string the caller typed. Login looks accounts up case-insensitively, so
-- `Victim@x.com` and `victim@x.com` are the same account — but they were
-- two different verification_codes rows, with two separate attempt
-- counters, two separate one-minute cooldowns, and two separate limiter
-- buckets. All of them delivered to the same inbox.
--
-- That is the V-1 attempt-limit fix undone by casing: an attacker gets
-- 5 attempts per spelling, and a victim gets one email per spelling.
-- Phone numbers had the same hole through spacing and punctuation
-- (`+94 77 123 4567` vs `+94771234567`).
--
-- # WHAT THIS ADDS
--
-- The service now normalises before it writes (that is the real fix).
-- This column and index are the database saying the same thing, so a
-- future call site that forgets cannot reopen the hole — the insert
-- fails instead of quietly creating a second budget.
--
-- GENERATED ALWAYS ... STORED, so it cannot drift from target and no
-- backfill statement is needed for it: Postgres computes it for every
-- existing row as part of the ALTER.
--
-- The expression is purpose-aware because the two targets normalise
-- differently and one rule would break the other. Email: lowercase and
-- trim — stripping punctuation would mangle `foo-bar@x.com`, where the
-- hyphen is part of the address. Phone: strip spaces, hyphens, brackets
-- and dots, which carry no meaning in E.164 and are exactly how the same
-- number gets typed two ways.

-- Expired rows first, as the plan allows. OTPs live ten minutes; anything
-- expired is already dead and deleting it avoids the index below tripping
-- over historical duplicates that only ever differed by casing.
DELETE FROM auth.verification_codes WHERE expires_at < now();

ALTER TABLE auth.verification_codes
    ADD COLUMN IF NOT EXISTS target_normalized TEXT
    GENERATED ALWAYS AS (
        CASE
            WHEN purpose = 'phone'
                THEN regexp_replace(btrim(target), '[[:space:]().-]', '', 'g')
            ELSE lower(btrim(target))
        END
    ) STORED;

-- Live duplicates that differ only by spelling: keep the newest row for
-- each normalised target and drop the rest, so the unique index below can
-- be built. Keeping the NEWEST matches what the application would have
-- done anyway — the most recent send is the code the user is looking at.
DELETE FROM auth.verification_codes a
 USING auth.verification_codes b
 WHERE a.user_id IS NULL
   AND b.user_id IS NULL
   AND a.purpose = b.purpose
   AND a.target_normalized = b.target_normalized
   AND (a.created_at, a.id) < (b.created_at, b.id);

-- Built BEFORE the old index is dropped, so there is no instant without
-- a uniqueness guarantee on this table.
CREATE UNIQUE INDEX IF NOT EXISTS idx_verification_codes_signup_target_normalized
    ON auth.verification_codes (purpose, target_normalized) WHERE user_id IS NULL;

DROP INDEX IF EXISTS auth.idx_verification_codes_signup_target;
