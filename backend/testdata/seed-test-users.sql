-- Eight seeded test accounts, two at each trust level 0-3.
--
-- NOT A MIGRATION. This lives in testdata/ and is applied by hand, on
-- purpose: migrations run automatically on every deploy, and eight accounts
-- with a bypassable login must never be something a deploy creates by
-- accident. Applying it is a decision someone makes each time.
--
-- # WHY THIS SETS EVIDENCE AND NOT trust_level
--
-- trust_level is a stored column, but it is DERIVED. computeTrustLevel
-- (internal/modules/auth/trustlevel.go) recomputes it from the evidence
-- columns on every trust-touching write, so a row whose trust_level was set
-- by hand reverts to whatever its evidence implies the next time anything
-- verifies. Seeding the level alone produces accounts that are the right
-- level until they are used, which is the worst possible failure mode for a
-- test fixture.
--
-- So each row below sets the EVIDENCE for its level, and trust_level is
-- written to the value that evidence computes to. The two agree, which means
-- a later recompute is a no-op rather than a correction:
--
--   Level 0  is_guest = true
--   Level 1  is_guest = false
--   Level 2  + linkedin_sub, phone_number, personal_email, legal_name
--   Level 3  + work_email_verified, company_name
--
-- Note the column CHECK allows trust_level 0..4, but computeTrustLevel never
-- returns 4 and no code path reads it. There is no Level 4. The constraint is
-- simply wider than the ladder.
--
-- # WHY .test ADDRESSES
--
-- .test is reserved by RFC 2606. It cannot be registered, cannot receive
-- mail, and cannot belong to a real person. That property is what makes it
-- safe to put these addresses in TEST_OTP_BYPASS_EMAILS: an allowlisted
-- address is effectively a published credential, so it must be one that can
-- never be a real mailbox. Never add a deliverable address to that allowlist.
--
-- # IDEMPOTENT
--
-- Fixed UUIDs, ON CONFLICT DO UPDATE. Re-running refreshes the rows rather
-- than erroring or duplicating. The UUID encodes the level (…0010 = L0 #1,
-- …0031 = L2 #2) so a test account is recognisable on sight in any log line.
--
-- Level 0 caveat: is_guest = true is what MAKES an account Level 0, and a
-- real guest has no email at all. These two carry an email anyway so they can
-- sign in through the email path - a state the app itself cannot produce.
-- Fine for exercising Level 0 gating in the UI; not a substitute for testing
-- the real one-tap guest signup flow.

INSERT INTO auth.users (
    id, full_name, trust_level, is_guest,
    linkedin_sub, phone_number, personal_email, legal_name,
    work_email_verified, work_email_verified_at, company_name, company_domain,
    age_confirmed_over_18, age_confirmed_at
) VALUES
    -- ---------- Level 0: guests ----------
    ('00000000-0000-4000-8000-000000000010', 'Test L0 Alpha', 0, true,
     NULL, NULL, 'l0.a@meetups.test', NULL,
     false, NULL, NULL, NULL,
     true, now()),
    ('00000000-0000-4000-8000-000000000011', 'Test L0 Bravo', 0, true,
     NULL, NULL, 'l0.b@meetups.test', NULL,
     false, NULL, NULL, NULL,
     true, now()),

    -- ---------- Level 1: real account, nothing verified beyond signup ----------
    ('00000000-0000-4000-8000-000000000020', 'Test L1 Alpha', 1, false,
     NULL, NULL, 'l1.a@meetups.test', NULL,
     false, NULL, NULL, NULL,
     true, now()),
    ('00000000-0000-4000-8000-000000000021', 'Test L1 Bravo', 1, false,
     NULL, NULL, 'l1.b@meetups.test', NULL,
     false, NULL, NULL, NULL,
     true, now()),

    -- ---------- Level 2: the full identity bundle ----------
    -- All four of linkedin_sub / phone_number / personal_email / legal_name
    -- are required together. Drop any one and this row computes to Level 1.
    ('00000000-0000-4000-8000-000000000030', 'Test L2 Alpha', 2, false,
     'test-linkedin-sub-l2-alpha', '+94700000030', 'l2.a@meetups.test', 'Test Level Two Alpha',
     false, NULL, NULL, NULL,
     true, now()),
    ('00000000-0000-4000-8000-000000000031', 'Test L2 Bravo', 2, false,
     'test-linkedin-sub-l2-bravo', '+94700000031', 'l2.b@meetups.test', 'Test Level Two Bravo',
     false, NULL, NULL, NULL,
     true, now()),

    -- ---------- Level 3: Level 2 plus verified employment ----------
    -- work_email_hash is deliberately left NULL. It is the reuse-abuse anchor
    -- for a REAL corporate verification (a keyed HMAC of the address), it is
    -- UNIQUE, and computeTrustLevel does not read it. Inventing values would
    -- add a collision surface for no behavioural gain.
    ('00000000-0000-4000-8000-000000000040', 'Test L3 Alpha', 3, false,
     'test-linkedin-sub-l3-alpha', '+94700000040', 'l3.a@meetups.test', 'Test Level Three Alpha',
     true, now(), 'Testcorp Alpha', 'testcorp.test',
     true, now()),
    ('00000000-0000-4000-8000-000000000041', 'Test L3 Bravo', 3, false,
     'test-linkedin-sub-l3-bravo', '+94700000041', 'l3.b@meetups.test', 'Test Level Three Bravo',
     true, now(), 'Testcorp Bravo', 'testcorp.test',
     true, now())

ON CONFLICT (id) DO UPDATE SET
    full_name              = EXCLUDED.full_name,
    trust_level            = EXCLUDED.trust_level,
    is_guest               = EXCLUDED.is_guest,
    linkedin_sub           = EXCLUDED.linkedin_sub,
    phone_number           = EXCLUDED.phone_number,
    personal_email         = EXCLUDED.personal_email,
    legal_name             = EXCLUDED.legal_name,
    work_email_verified    = EXCLUDED.work_email_verified,
    work_email_verified_at = EXCLUDED.work_email_verified_at,
    company_name           = EXCLUDED.company_name,
    company_domain         = EXCLUDED.company_domain,
    age_confirmed_over_18  = EXCLUDED.age_confirmed_over_18,
    age_confirmed_at       = EXCLUDED.age_confirmed_at,
    updated_at             = now();

-- The meetup module keeps its own copy of each user's name/photo/level
-- (meetup.user_display_cache), normally filled by the user-onboarded /
-- profile-updated outbox events a real sign-up emits. A seeded user never
-- emits those, so without this their name is blank on every card, request
-- row and participant list. Same upsert shape as UpsertUserDisplayCache.
INSERT INTO meetup.user_display_cache (user_id, full_name, profile_photo_url, trust_level, updated_at)
SELECT id, full_name, NULL, trust_level, now()
FROM auth.users
WHERE id::text LIKE '00000000-0000-4000-8000-0000000000%'
ON CONFLICT (user_id) DO UPDATE
SET full_name = excluded.full_name,
    trust_level = excluded.trust_level,
    updated_at = excluded.updated_at;

-- Verification: every row's stored trust_level must equal what the evidence
-- implies. Mirrors computeTrustLevel exactly. If this reports any row, the
-- seed and the Go logic have drifted and the fixtures are lying.
SELECT
    personal_email,
    trust_level AS stored,
    CASE
        WHEN linkedin_sub IS NOT NULL AND phone_number IS NOT NULL
             AND personal_email IS NOT NULL AND legal_name IS NOT NULL
             AND work_email_verified AND company_name IS NOT NULL THEN 3
        WHEN linkedin_sub IS NOT NULL AND phone_number IS NOT NULL
             AND personal_email IS NOT NULL AND legal_name IS NOT NULL THEN 2
        WHEN NOT is_guest THEN 1
        ELSE 0
    END AS computed
FROM auth.users
WHERE id::text LIKE '00000000-0000-4000-8000-0000000000%'
ORDER BY personal_email;
