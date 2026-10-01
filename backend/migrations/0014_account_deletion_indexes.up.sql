-- Indexes for account deletion (2026-09-28).
--
-- Deleting an account touches seventeen tables by user id: four in auth via
-- ON DELETE CASCADE, two more in auth deleted explicitly (trusted_contacts
-- and sos_events carry no FK), and eleven in meetup via PurgeUser (nine
-- deleted, two anonymised in place). Most of those columns were already
-- indexed. These six were not, and an unindexed predicate here is not a
-- micro-optimisation: it is a SEQUENTIAL SCAN taken while holding row locks
-- inside the delete's transaction, on tables that only grow. At a few
-- thousand rows nobody notices; at a few million one user deleting their
-- account stalls writes for everyone.
--
-- Measured on 200k rows before shipping: the ratings predicate below planned
-- a seq scan at cost 4773, and an index scan at 8.44 once its index existed.
--
-- Postgres does NOT create an index for a foreign key automatically. The
-- parent-side DELETE has to find the children somehow, so an unindexed FK
-- column means a full scan of the child table per cascade.

-- Hit by the cascade from auth.users. Neither column was indexed at all.
CREATE INDEX IF NOT EXISTS idx_verification_codes_user_id
  ON auth.verification_codes (user_id);

CREATE INDEX IF NOT EXISTS idx_unverified_company_claims_user_id
  ON auth.unverified_company_claims (user_id);

-- Hit by PurgeUser. Both tables have a PRIMARY KEY (meetup_id, user_id),
-- which cannot serve `WHERE user_id = $1`: user_id is the SECOND column, and
-- a btree can only seek on a prefix of its key. The composite PK stays as it
-- is — it is right for every other access path these tables have, which is
-- always "this meetup, this member".
CREATE INDEX IF NOT EXISTS idx_safety_state_user_id
  ON meetup.safety_state (user_id);

CREATE INDEX IF NOT EXISTS idx_meetup_feedback_user_id
  ON meetup.meetup_feedback (user_id);

-- Same reason, third table: safety_share's PRIMARY KEY is
-- (meetup_id, user_id, contact_id), with user_id second.
CREATE INDEX IF NOT EXISTS idx_safety_share_user_id
  ON meetup.safety_share (user_id);

-- Hit by PurgeUser's AnonymiseRatingsGivenByUser (`WHERE rater_user_id =
-- $1`). The other direction already has idx_meetup_user_ratings_rated, but
-- rater_user_id only ever appears as the SECOND column of
-- UNIQUE (meetup_id, rater_user_id, rated_user_id), which cannot seek on it.
-- Ratings are the fastest-growing table here (one row per pair per meetup),
-- so this is the scan that would hurt first.
CREATE INDEX IF NOT EXISTS idx_meetup_user_ratings_rater
  ON meetup.meetup_user_ratings (rater_user_id);

-- Plain CREATE INDEX, not CONCURRENTLY, matching 0013 and the rest of this
-- directory: CONCURRENTLY cannot run inside a transaction, and golang-migrate
-- wraps each migration in one. A plain build takes a SHARE lock (reads
-- continue, writes wait) for as long as the build takes — milliseconds at
-- this data size, which 0013 confirmed by applying in 770ms. Revisit if any
-- of these tables ever reaches a size where that pause is noticeable.
