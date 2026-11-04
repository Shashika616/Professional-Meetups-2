-- Plan 30D: a user's own photo, one small JPEG in Postgres. No bucket and no
-- image server. A table of its own, so ordinary user reads never load image
-- bytes. Goes with the account (ON DELETE CASCADE).
--
-- auth.users.profile_photo_url stays, and from here it holds our own path,
-- /v1/users/{id}/photo?v=<etag>, or nothing: the same field the display
-- cache already copies through the user-profile event. External LinkedIn
-- addresses left in it are replaced by cmd/backfill-photos (runbook §3a).
CREATE TABLE auth.user_photos (
    user_id    UUID PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
    jpeg       BYTEA NOT NULL,
    etag       TEXT NOT NULL,
    width      INTEGER NOT NULL,
    height     INTEGER NOT NULL,
    bytes      INTEGER NOT NULL CHECK (bytes <= 102400),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
