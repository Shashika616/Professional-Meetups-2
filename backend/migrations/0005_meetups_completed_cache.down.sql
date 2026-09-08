-- Reverses 0005_meetups_completed_cache.up.sql.
--
-- A clean undo, unlike 0004's: these columns are a derived cache with no
-- authority of their own. Dropping them loses nothing that cannot be
-- rebuilt — the meetup module still holds every completed meetup and every
-- accepted request the count was computed from.
ALTER TABLE auth.users
    DROP COLUMN IF EXISTS meetups_completed_updated_at;

ALTER TABLE auth.users
    DROP COLUMN IF EXISTS meetups_completed;
