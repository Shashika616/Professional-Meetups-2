-- The terms and privacy policy, one row per published version. The newest is
-- current. Published with cmd/legaladmin, so a change needs no deploy and no
-- app release. Empty until the first version is published.
CREATE TABLE ops.legal_documents (
    version      TEXT PRIMARY KEY,
    terms        TEXT NOT NULL,
    privacy      TEXT NOT NULL,
    published_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Which version of the terms and privacy policy each user agreed to, and when.
-- One row per user and version, so accepting a new version keeps the history.
-- Goes with the account, like the rest of a user's data (ADR-008).
CREATE TABLE auth.legal_acceptances (
    user_id     UUID NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
    version     TEXT NOT NULL,
    app_version TEXT NOT NULL DEFAULT '',
    platform    TEXT NOT NULL DEFAULT '',
    accepted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, version)
);

-- Both start off. legal.acceptance.required stays off until the documents
-- are final. app.force_update is set with billingadmin when a release must be
-- forced (docs/deploy/deployment-guide.md).
INSERT INTO ops.feature_flags (key, enabled, rules, value) VALUES
    ('legal.acceptance.required', false, '[]', NULL),
    ('app.force_update', false, '[]',
     '{"min_version":{"ios":"","android":""},"message":"","store_url":{"ios":"","android":""}}')
ON CONFLICT (key) DO NOTHING;
