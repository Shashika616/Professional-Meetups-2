-- Drops everything 0001_auth_schema.up.sql created. One statement, because
-- every object in that migration lives inside the auth schema (including its
-- enum types and its set_updated_at trigger function) — that is exactly the
-- containment ADR-001 §3's schema-per-module decision buys.
--
-- pgcrypto is deliberately NOT dropped: it is installed into public, it is
-- not owned by this module, and later modules' migrations need it too.
DROP SCHEMA IF EXISTS auth CASCADE;
