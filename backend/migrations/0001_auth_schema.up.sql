-- auth module schema (ADR-001 §3: one database, one Postgres schema per
-- module). This is the squashed final state of the sibling microservices
-- repo's ten auth migrations
-- (../../Professional-Meetups/backend/db/migrations/auth/0001..0010) — same
-- eight tables, same columns/constraints/indexes/triggers, schema-qualified
-- under `auth.` instead of living at the top level of their own database.
-- Squashed rather than replayed one-for-one because this repo has no
-- deployed database to migrate forward from: there is one migration history
-- here (backend/migrations/), and every phase adds its own module's schema
-- file to it (meetup, billing — Phases 2/3).
--
-- What is deliberately NOT here, relative to those ten migrations:
--
--   * `outbox_events` (their 0005) — ADR-001 §4 replaces the transactional
--     outbox + relay with the in-process event bus, so the table, the relay
--     and the circuit breaker in front of it all go away. Events are
--     published by internal/eventbus in the same call as the business write.
--   * `password_hash` (their 0003, dropped again in their 0006) — never
--     added here in the first place. The email path is OTP-only (ADR-019 §1
--     in the sibling repo).
--
-- Cross-module foreign keys: none, ever (ADR-001 §3). Every FK below points
-- at auth.users from within the auth schema itself, which is exactly what
-- the source schema does. The two columns the source deliberately leaves as
-- "logical FK, no real constraint" — trusted_contacts.user_id and
-- sos_events.user_id — stay unconstrained here too, even though one database
-- now makes a real FK physically possible: adding one would be precisely the
-- coupling that makes re-extracting a module a data-migration project.

CREATE SCHEMA IF NOT EXISTS auth;

CREATE EXTENSION IF NOT EXISTS pgcrypto; -- for gen_random_uuid()

CREATE TYPE auth.account_status AS ENUM ('active', 'deactivated', 'deleted');

-- One shared OTP mechanism, five purposes — not five separate mechanisms.
-- The last two (email_signup, email_login) are the ones with no user_id at
-- OTP-send time; their rows are keyed by (purpose, target) instead, via
-- idx_verification_codes_signup_target below.
CREATE TYPE auth.verification_purpose AS ENUM (
    'phone',
    'personal_email',
    'corporate_email',
    'email_signup',
    'email_login'
);

-- Apple/Google only. LinkedIn is deliberately NOT a value here: its identity
-- lives on users.linkedin_sub directly, both for direct signup and for
-- Profile-linking, so there is exactly one place to check "does this user
-- have LinkedIn."
CREATE TYPE auth.identity_provider AS ENUM ('apple', 'google');

CREATE TABLE auth.users (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- The OIDC 'sub' claim LinkedIn returns. Presence of a value here IS the
    -- signal that this user has connected LinkedIn — there is deliberately
    -- no separate "linkedin_connected" boolean duplicating that fact. NULL
    -- is a real, expected state (a Level 0 federated/email-only account).
    linkedin_sub       TEXT UNIQUE,

    full_name          TEXT NOT NULL,
    profile_photo_url  TEXT,
    headline           TEXT,

    -- DEFAULT 0, not 1: a fresh row before computeTrustLevel runs should
    -- reflect Level 0, not overclaim Level 1.
    trust_level        SMALLINT NOT NULL DEFAULT 0 CHECK (trust_level BETWEEN 0 AND 4),
    account_status     auth.account_status NOT NULL DEFAULT 'active',

    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Level 2/3 verification. Presence of the value IS the verified signal,
    -- same convention as linkedin_sub — work_email_verified is the one
    -- deliberate exception (an explicit bool), and company_domain is never
    -- the raw corporate email address, only its domain half.
    phone_number           TEXT,
    personal_email         TEXT,
    legal_name             TEXT,
    address                TEXT,
    company_domain         TEXT,
    work_email_verified    BOOLEAN NOT NULL DEFAULT false,
    work_email_verified_at TIMESTAMPTZ,

    -- 18+ self-attestation: deliberately no date of birth stored.
    age_confirmed_over_18  BOOLEAN NOT NULL DEFAULT false,
    age_confirmed_at       TIMESTAMPTZ,

    -- Reuse-abuse anchor for corporate-email verification: a keyed HMAC of
    -- the normalized raw address, never a plain hash of the address alone (a
    -- plain hash of a well-known firstname.lastname@company.com format is
    -- trivially reversible by dictionary attack). UNIQUE detects "this exact
    -- mailbox already verified a different account" without ever retaining a
    -- reversible copy of the address itself.
    work_email_hash        TEXT UNIQUE,

    -- Read-only CACHE of the rating aggregate the meetup module owns and
    -- computes (Phase 2). Kept, not replaced with a cross-schema join, per
    -- ADR-001 §3 — same eventual-consistency model as today, fed by a
    -- rating-updated event over the in-process bus instead of Pub/Sub.
    -- rating_updated_at is its own column, not a reuse of users.updated_at
    -- (which the trigger below bumps on ANY field change), because the
    -- consumer's ordering guard needs to compare against when the rating
    -- cache specifically was last written.
    rating_average     NUMERIC(3,2) NOT NULL DEFAULT 0,
    rating_count       INTEGER NOT NULL DEFAULT 0,
    rating_updated_at  TIMESTAMPTZ,

    -- A coarse, infrequently-refreshed last-known location, written only by
    -- UpdateLastKnownLocation (the browse screen's on-demand read, exactly
    -- one call site). Never exposed to any other user or API response.
    last_location_lat        DOUBLE PRECISION,
    last_location_lng        DOUBLE PRECISION,
    last_location_updated_at TIMESTAMPTZ
);

-- Partial indexes: these columns are nullable and only ever looked up when
-- present. Non-null values must be unique platform-wide — they are real
-- secondary identity anchors, not just verified profile fields.
CREATE UNIQUE INDEX idx_users_linkedin_sub ON auth.users (linkedin_sub) WHERE linkedin_sub IS NOT NULL;
CREATE UNIQUE INDEX idx_users_phone_number ON auth.users (phone_number) WHERE phone_number IS NOT NULL;
CREATE UNIQUE INDEX idx_users_personal_email ON auth.users (personal_email) WHERE personal_email IS NOT NULL;

CREATE TABLE auth.refresh_tokens (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

    -- SHA-256 of the actual refresh token, hex-encoded. The raw token is
    -- returned to the client exactly once and never stored — this table can
    -- only recognize a presented token, never reproduce it.
    token_hash    TEXT NOT NULL UNIQUE,

    issued_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at    TIMESTAMPTZ NOT NULL,
    revoked_at    TIMESTAMPTZ,

    -- Set when this token was rotated out for a newer one. A presented token
    -- whose row already has replaced_by set is a replay of an old,
    -- already-rotated token — treat as a theft signal.
    replaced_by   UUID REFERENCES auth.refresh_tokens(id)
);

CREATE INDEX idx_refresh_tokens_user_id ON auth.refresh_tokens (user_id);

CREATE TABLE auth.verification_codes (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Nullable for the email_signup/email_login purposes only: there is no
    -- user_id yet at OTP-send time (the account may never end up created).
    user_id     UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    purpose     auth.verification_purpose NOT NULL,
    -- The phone number or email address being verified; deleted once
    -- verified or expired (minimal retention, load-bearing for the
    -- corporate-email case).
    target      TEXT NOT NULL,
    -- SHA-256 of the OTP, same pattern as refresh_tokens.token_hash.
    code_hash   TEXT NOT NULL,
    attempts    SMALLINT NOT NULL DEFAULT 0,
    expires_at  TIMESTAMPTZ NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- One pending code per user per purpose — a new send overwrites
    -- (upsert), it doesn't stack. Also what makes the 1-minute resend timer
    -- server-enforceable in one indexed lookup.
    UNIQUE (user_id, purpose)
);

-- The (purpose, target)-keyed equivalent, for the two purposes whose rows
-- have no user_id at all.
CREATE UNIQUE INDEX idx_verification_codes_signup_target
    ON auth.verification_codes (purpose, target) WHERE user_id IS NULL;

CREATE TABLE auth.user_identities (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    provider    auth.identity_provider NOT NULL,
    subject     TEXT NOT NULL,       -- the provider's stable 'sub' claim
    email       TEXT,                -- from the verified id_token, display-only, not an identity anchor
    linked_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (provider, subject),      -- one provider identity can't attach to two users
    UNIQUE (user_id, provider)       -- a user can't link the same provider twice
);

CREATE INDEX idx_user_identities_user_id ON auth.user_identities (user_id);

CREATE TABLE auth.known_companies (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Lowercased, whitespace-collapsed input name — matching happens against
    -- this column, never a separate raw display name.
    name_normalized TEXT NOT NULL UNIQUE,
    domains         TEXT[] NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- domainFromEmail lowercases before comparing against domains (domain
    -- names are case-insensitive, RFC 4343), which only works if every
    -- stored domain is already lowercase. Postgres CHECK constraints can't
    -- contain a subquery even over the row's own array column, so this
    -- compares the array flattened to a single string against its own
    -- lowercased form instead of unnest()-ing it — equivalent for this
    -- purpose (any uppercase character anywhere in any element changes the
    -- flattened string).
    CONSTRAINT known_companies_domains_lowercase
        CHECK (array_to_string(domains, ',') = lower(array_to_string(domains, ',')))
);

-- MVP reference set, not exhaustive — same posture as the free-email/
-- role-based-address reject lists in the auth module's otp.go. Growable over
-- time by whoever eventually owns this.
INSERT INTO auth.known_companies (name_normalized, domains) VALUES
    ('commercial bank of ceylon',        ARRAY['combank.lk']),
    ('sampath bank',                     ARRAY['sampath.lk']),
    ('hatton national bank',             ARRAY['hnb.net']),
    ('bank of ceylon',                   ARRAY['boc.lk']),
    ('peoples bank',                     ARRAY['peoplesbank.lk']),
    ('dialog axiata',                    ARRAY['dialog.lk']),
    ('sri lanka telecom',                ARRAY['slt.lk']),
    ('mobitel',                          ARRAY['mobitel.lk']),
    ('virtusa',                          ARRAY['virtusa.com']),
    ('wso2',                             ARRAY['wso2.com']),
    ('ifs',                              ARRAY['ifs.com']),
    ('sysco labs',                       ARRAY['syscolabs.com']),
    ('mas holdings',                     ARRAY['masholdings.com']),
    ('john keells holdings',             ARRAY['keells.com']),
    ('university of moratuwa',           ARRAY['uom.lk']),
    ('university of colombo',            ARRAY['cmb.ac.lk'])
ON CONFLICT (name_normalized) DO NOTHING;

-- Manual-review queue for unknown-company (name, domain) pairs flagged at
-- verification time — no reviewer UI, just the queue itself.
CREATE TABLE auth.unverified_company_claims (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id              UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    company_name_entered TEXT NOT NULL,
    domain               TEXT NOT NULL,
    flagged_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_unverified_company_claims_flagged_at ON auth.unverified_company_claims (flagged_at);

-- Trusted contacts are a property of the user, not any specific meetup, so
-- they live in the auth module. Soft cap of 3 per user is enforced at the
-- service layer, not a DB constraint.
CREATE TABLE auth.trusted_contacts (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL, -- deliberately no FK (see this file's header)
    name         TEXT NOT NULL,
    phone_number TEXT,
    email        TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (phone_number IS NOT NULL OR email IS NOT NULL)
);

CREATE INDEX idx_trusted_contacts_user_id ON auth.trusted_contacts (user_id);

-- This flow's own audit trail from day one. Not the general-purpose
-- tamper-evident audit log, which stays a separately tracked gap.
CREATE TABLE auth.sos_events (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           UUID NOT NULL, -- deliberately no FK (see this file's header)
    context_message   TEXT,
    latitude          DOUBLE PRECISION NOT NULL,
    longitude         DOUBLE PRECISION NOT NULL,
    triggered_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    contacts_notified INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX idx_sos_events_user_id ON auth.sos_events (user_id);

-- updated_at should always reflect the last write, without every call site
-- having to remember to set it by hand. Lives in the auth schema rather than
-- public: a later module's migration adding its own trigger function must
-- not collide with (or silently depend on) this one.
CREATE OR REPLACE FUNCTION auth.set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_set_updated_at
    BEFORE UPDATE ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION auth.set_updated_at();

CREATE TRIGGER trusted_contacts_set_updated_at
    BEFORE UPDATE ON auth.trusted_contacts
    FOR EACH ROW
    EXECUTE FUNCTION auth.set_updated_at();
