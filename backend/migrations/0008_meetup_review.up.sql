-- The post-meetup review (one flow, three parts): an overall score for the
-- meetup itself, a per-participant score, and a small set of personality
-- traits per participant.
--
-- # WHY A REVIEW IS A DISTINCT THING FROM THE RATINGS IT CONTAINS
--
-- meetup_user_ratings already recorded one immutable 1-5 score per pair,
-- and meetup_feedback already recorded "did this happen / did I feel safe".
-- Neither answers "has this person finished reviewing this meetup", which is
-- what decides whether the meetup still needs the user's attention on Home.
-- Inferring it from "have they rated everyone" would be wrong in both
-- directions: a solo meetup has nobody to rate, and a partially-rated meetup
-- is not a finished review.
--
-- So review_completed_at is written once, by the Confirm at the end of the
-- flow, and is the single fact the Home list reads.

ALTER TABLE meetup.meetup_feedback
    -- "How was your experience?" — the 1-5 slider, about the MEETUP, not
    -- about any person on it. Nullable because every meetup_feedback row
    -- that predates this migration has no answer, and because a
    -- "didn't happen" report legitimately has none.
    ADD COLUMN overall_score SMALLINT CHECK (overall_score BETWEEN 1 AND 5),
    -- Set by the review flow's Confirm. Null = still owed.
    ADD COLUMN review_completed_at TIMESTAMPTZ;

-- Traits are a closed, server-defined vocabulary (see traits.go) validated
-- on write. TEXT[] rather than a join table: they are a small fixed set
-- read only alongside their rating row, never queried across, and a join
-- table would add a second write to every rating for no read anyone makes.
ALTER TABLE meetup.meetup_user_ratings
    ADD COLUMN traits TEXT[] NOT NULL DEFAULT '{}';

-- Home asks "which of my meetups still need reviewing", which is a lookup
-- by user over unfinished rows.
CREATE INDEX idx_meetup_feedback_user_incomplete
    ON meetup.meetup_feedback (user_id)
    WHERE review_completed_at IS NULL;
