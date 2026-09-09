DROP INDEX IF EXISTS meetup.idx_meetup_feedback_user_incomplete;
ALTER TABLE meetup.meetup_user_ratings DROP COLUMN IF EXISTS traits;
ALTER TABLE meetup.meetup_feedback
    DROP COLUMN IF EXISTS review_completed_at,
    DROP COLUMN IF EXISTS overall_score;
