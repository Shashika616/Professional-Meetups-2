-- meetup module schema (ADR-001 §3: one database, one Postgres schema per
-- module). Squashed final state of the source's twelve meetup migrations
-- (../../Professional-Meetups/backend/db/migrations/meetup/0001..0012),
-- schema-qualified under `meetup.` — same approach as Phase 1's auth schema,
-- and for the same reason: there is no deployed database here to migrate
-- forward from, so each phase contributes one final-state file to the single
-- migration history.
--
-- What is deliberately NOT here, relative to those twelve:
--
--   * `outbox_events` (their 0005) — ADR-001 §4 replaces the transactional
--     outbox + relay with the in-process event bus.
--   * `scheduled_for` (added in their 0001, dropped in their 0002) and the
--     pre-window backfill around it — never added here in the first place.
--   * The 0001 shape of `meetup_safety_state` (one row per meetup), which
--     their 0007 drops and recreates per-participant. Built per-participant
--     directly; see safety_state below.
--
-- Cross-module foreign keys: none (ADR-001 §3). Every `user_id`-shaped
-- column below (`meetups.host_user_id`, `meetup_requests.requester_id`,
-- `safety_state.user_id`, `meetup_feedback.user_id`, `device_tokens.user_id`,
-- `meetup_user_ratings.rater_user_id`/`rated_user_id`, and the three caches'
-- `user_id` primary keys) stays a plain UUID with no REFERENCES auth.users.
-- In the source that was physically unavoidable (separate databases); here it
-- is a deliberate choice to keep the module re-extractable. FKs WITHIN the
-- meetup schema are kept exactly as the source has them.

CREATE SCHEMA IF NOT EXISTS meetup;

-- pgcrypto is already installed by 0001_auth_schema (gen_random_uuid);
-- postgis is not — Phase 1's schema has no geospatial data. Confirmed
-- against that file rather than assumed, so this doesn't double-create.
-- The image is postgis/postgis, so the extension is available to install.
CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TYPE meetup.meetup_status AS ENUM ('open', 'full', 'cancelled', 'completed');
CREATE TYPE meetup.meetup_request_status AS ENUM ('pending', 'accepted', 'rejected', 'withdrawn');

-- Server-side mirror of the frontend's IntentType (frontend/lib/core/models/
-- intent_type.dart) — a change to one side (adding/renaming an intent) must
-- be made on the other too, the same explicit-duplication note the auth
-- module's OTP domain-rejection lists carry.
CREATE TYPE meetup.intent_type AS ENUM ('coffee', 'lunch', 'networking', 'mentorship', 'ride_share', 'dating');

CREATE TABLE meetup.meetups (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    host_user_id    UUID NOT NULL, -- deliberately no FK (see this file's header)
    intent          meetup.intent_type NOT NULL,
    location_lat    DOUBLE PRECISION NOT NULL,
    location_lng    DOUBLE PRECISION NOT NULL,
    -- Formatted address string, display-only — never used for anything
    -- security-relevant server-side.
    location_label  TEXT NOT NULL,
    capacity        SMALLINT NOT NULL CHECK (capacity BETWEEN 1 AND 20),
    status          meetup.meetup_status NOT NULL DEFAULT 'open',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    cancelled_at    TIMESTAMPTZ,

    -- Time window (their 0002) — replaced the original single-instant
    -- scheduled_for.
    window_start    TIMESTAMPTZ NOT NULL,
    window_end      TIMESTAMPTZ NOT NULL,
    closed_at       TIMESTAMPTZ,

    -- Cancellation reason (their 0006), nullable: an older cancelled row
    -- simply has none, which the frontend renders as "no reason given".
    cancellation_reason TEXT,

    -- The lifecycle poller's starting-soon de-dup guard (their 0009): NULL
    -- until that push has been sent once, so a later tick's
    -- `starting_soon_notified_at IS NULL` predicate never re-notifies.
    starting_soon_notified_at TIMESTAMPTZ,

    -- PostGIS geography (their 0011), kept in sync from location_lat/lng by
    -- the trigger below. The plain lat/lng columns are deliberately KEPT
    -- alongside it, exactly as in the source — dropping them is a separate,
    -- later cleanup once every call site is confirmed on this column.
    location        geography(Point, 4326),

    CONSTRAINT meetups_window_valid CHECK (window_end > window_start)
);

CREATE INDEX idx_meetups_intent_status ON meetup.meetups (intent, status) WHERE status = 'open';
CREATE INDEX idx_meetups_host ON meetup.meetups (host_user_id);

-- One partial index covering both lifecycle sweeps' shared
-- `status IN ('open','full')` predicate, with window_start/window_end as the
-- index columns so both range conditions get an index range scan instead of
-- a sequential scan every 60 seconds. starting_soon_notified_at is
-- deliberately NOT in the WHERE clause — that would exclude rows the
-- auto-close sweep still needs.
CREATE INDEX idx_meetups_lifecycle_sweep ON meetup.meetups (window_start, window_end)
    WHERE status IN ('open', 'full');

CREATE TABLE meetup.meetup_requests (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    meetup_id       UUID NOT NULL REFERENCES meetup.meetups(id) ON DELETE CASCADE,
    requester_id    UUID NOT NULL, -- deliberately no FK (see this file's header)
    status          meetup.meetup_request_status NOT NULL DEFAULT 'pending',
    -- Set when auto-rejected for capacity, distinct from a host's explicit
    -- rejection — the frontend shows different copy for each.
    auto_rejected   BOOLEAN NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at     TIMESTAMPTZ,
    -- Withdrawal note (their 0006), nullable.
    withdrawal_note TEXT,
    -- One active request per user per meetup — re-requesting after
    -- withdrawing is allowed (no UNIQUE across all rows), but not two
    -- simultaneous pending/accepted requests from the same person.
    UNIQUE (meetup_id, requester_id, status) DEFERRABLE INITIALLY IMMEDIATE
);

CREATE INDEX idx_meetup_requests_meetup ON meetup.meetup_requests (meetup_id, status);
CREATE INDEX idx_meetup_requests_requester ON meetup.meetup_requests (requester_id);

-- Safety Gate state, ONE ROW PER PARTICIPANT — matching meetup_feedback's
-- shape, not one shared row per meetup.
--
-- This is the source's own final shape (its 0007 drops and recreates the
-- 0001 table for exactly this), decided in that repo's ADR-024 §1 and built
-- + independently verified there. Building it directly rather than
-- replaying drop-and-recreate: this repo has no data to migrate.
--
-- Kept as its own table rather than columns on meetups because it is a
-- different retention/sensitivity class — live-location sharing in
-- particular should be purgeable independently of the meetup record.
CREATE TABLE meetup.safety_state (
    meetup_id            UUID NOT NULL REFERENCES meetup.meetups(id) ON DELETE CASCADE,
    user_id              UUID NOT NULL, -- deliberately no FK (see this file's header)
    checklist_ack_at     TIMESTAMPTZ,
    live_location_opt_in BOOLEAN NOT NULL DEFAULT false,
    checked_in_at        TIMESTAMPTZ,
    declined_at          TIMESTAMPTZ,
    decline_reason       TEXT,
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (meetup_id, user_id)
);

CREATE TABLE meetup.meetup_feedback (
    meetup_id         UUID NOT NULL REFERENCES meetup.meetups(id) ON DELETE CASCADE,
    user_id           UUID NOT NULL, -- deliberately no FK (see this file's header)
    happened          BOOLEAN NOT NULL,
    felt_safe         BOOLEAN,
    profile_accurate  BOOLEAN,
    would_meet_again  BOOLEAN,
    submitted_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Free-text note (their 0002), never gated on `happened` — a note is
    -- meaningful either way (e.g. "never showed up").
    notes             TEXT,
    PRIMARY KEY (meetup_id, user_id)
);

-- A separate table (not a column on users) since a user's registered
-- device(s) change independently of their identity record. UNIQUE on
-- fcm_token, not a composite key — a token identifies one physical device
-- install; if it is later registered under a different account (shared
-- device, account switch), upserting by token reassigns ownership rather
-- than leaving a stale row pointing at the previous account.
CREATE TABLE meetup.device_tokens (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL, -- deliberately no FK (see this file's header)
    fcm_token   TEXT NOT NULL UNIQUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_device_tokens_user_id ON meetup.device_tokens (user_id);

CREATE TABLE meetup.meetup_user_ratings (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    meetup_id       UUID NOT NULL REFERENCES meetup.meetups(id) ON DELETE CASCADE,
    rater_user_id   UUID NOT NULL, -- deliberately no FK (see this file's header)
    rated_user_id   UUID NOT NULL,
    score           SMALLINT NOT NULL CHECK (score BETWEEN 1 AND 5),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Backstop against a malformed direct API call — the UI never offers
    -- self as a rateable option, so this only fires there. The service layer
    -- checks it too; both are deliberate.
    CHECK (rater_user_id <> rated_user_id),
    -- One rating per pair per meetup, immutable (no edit/re-rate) — a second
    -- SubmitRating for the same pair hits this and maps to ErrConflict.
    UNIQUE (meetup_id, rater_user_id, rated_user_id)
);

CREATE INDEX idx_meetup_user_ratings_rated ON meetup.meetup_user_ratings (rated_user_id);

-- === event-fed read models (ADR-001 §3: kept, not collapsed into a join) ===
--
-- These three exist because cross-database reads were impossible in the
-- source. In one database they COULD be replaced with a cross-schema join —
-- and deliberately are not: that would reintroduce exactly the coupling that
-- makes a module impossible to re-extract. Same eventual-consistency model,
-- same idempotent-upsert-with-timestamp-guard, fed by the in-process bus
-- instead of Pub/Sub.

-- Populated by consuming user-onboarded / user-profile-updated. Holds only
-- what this module displays on a meetup/request card. rating_average/
-- rating_count are deliberately NOT here — this module computes those live
-- from its own meetup_user_ratings; only auth's copy needs an event, in the
-- reverse direction.
CREATE TABLE meetup.user_display_cache (
    user_id           UUID PRIMARY KEY, -- deliberately no FK (see this file's header)
    full_name         TEXT NOT NULL,
    profile_photo_url TEXT,
    trust_level       SMALLINT NOT NULL,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Populated by consuming user-location-updated. NOT what ListOpenMeetups'
-- viewer-side radius filter reads (that uses the caller's own fresh
-- on-demand coordinate, passed per request) — this backs the meetup-created
-- nearby-notify fan-out, which needs other users' last-known locations.
CREATE TABLE meetup.user_location_cache (
    user_id     UUID PRIMARY KEY, -- deliberately no FK (see this file's header)
    lat         DOUBLE PRECISION NOT NULL,
    lng         DOUBLE PRECISION NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    location    geography(Point, 4326)
);

-- Populated by consuming subscription-activated / subscription-deactivated.
-- Nothing publishes those until Phase 3 (billing) — the table and its
-- consumer are wired now anyway, the same bootstrapping pattern Phase 1 used
-- for publishing events nothing consumed yet.
CREATE TABLE meetup.subscription_cache (
    user_id     UUID PRIMARY KEY, -- deliberately no FK (see this file's header)
    tier        TEXT NOT NULL,
    entitled    BOOLEAN NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- === triggers ===

-- Lives in the meetup schema rather than public, same containment reasoning
-- as auth.set_updated_at(): a later module's migration must not collide with
-- (or silently depend on) this one.
CREATE OR REPLACE FUNCTION meetup.set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER device_tokens_set_updated_at
    BEFORE UPDATE ON meetup.device_tokens
    FOR EACH ROW
    EXECUTE FUNCTION meetup.set_updated_at();

CREATE TRIGGER safety_state_set_updated_at
    BEFORE UPDATE ON meetup.safety_state
    FOR EACH ROW
    EXECUTE FUNCTION meetup.set_updated_at();

-- Keeps `location` in sync from location_lat/location_lng on every
-- INSERT/UPDATE. This is the whole point: CreateMeetup and every other write
-- path that touches the plain coordinates needs no change at all to populate
-- the geography column correctly.
--
-- ST_MakePoint takes (x, y) = (lng, lat) — the classic ordering gotcha,
-- called out here so it doesn't get flipped.
CREATE OR REPLACE FUNCTION meetup.sync_meetups_location() RETURNS TRIGGER AS $$
BEGIN
    NEW.location = ST_SetSRID(ST_MakePoint(NEW.location_lng, NEW.location_lat), 4326)::geography;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER meetups_sync_location
    BEFORE INSERT OR UPDATE ON meetup.meetups
    FOR EACH ROW
    EXECUTE FUNCTION meetup.sync_meetups_location();

CREATE OR REPLACE FUNCTION meetup.sync_user_location_cache_location() RETURNS TRIGGER AS $$
BEGIN
    NEW.location = ST_SetSRID(ST_MakePoint(NEW.lng, NEW.lat), 4326)::geography;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER user_location_cache_sync_location
    BEFORE INSERT OR UPDATE ON meetup.user_location_cache
    FOR EACH ROW
    EXECUTE FUNCTION meetup.sync_user_location_cache_location();

-- The real spatial indexes — GiST is what gives these logarithmic-time
-- lookups, unlike the plain lat/lng columns a haversine expression reads
-- from (no index can help that at all).
CREATE INDEX idx_meetups_location_gist ON meetup.meetups USING GIST (location);
CREATE INDEX idx_user_location_cache_location_gist ON meetup.user_location_cache USING GIST (location);
