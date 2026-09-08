-- Drops everything 0002_meetup_schema.up.sql created. One statement, because
-- every object in that migration lives inside the meetup schema (its enum
-- types, its trigger functions, its tables) — the containment ADR-001 §3's
-- schema-per-module decision buys.
--
-- postgis is deliberately NOT dropped: like pgcrypto, it is installed into
-- public, is not owned by this module, and a later module may depend on it.
DROP SCHEMA IF EXISTS meetup CASCADE;
