-- Plan 30B, #111 (review N1-A3): an unknown company at work-email
-- verification no longer grants Level 3 before anyone has looked. The claim
-- row says where it stands. Existing rows predate the rule and were already
-- granted Level 3; they are marked 'pending_review' too, so the queue shows
-- them, without changing any account's level.
ALTER TABLE auth.unverified_company_claims
    ADD COLUMN status TEXT NOT NULL DEFAULT 'pending_review'
        CHECK (status IN ('pending_review', 'approved', 'rejected')),
    ADD COLUMN reviewed_at TIMESTAMPTZ;
CREATE INDEX idx_unverified_company_claims_pending
    ON auth.unverified_company_claims (flagged_at) WHERE status = 'pending_review';
