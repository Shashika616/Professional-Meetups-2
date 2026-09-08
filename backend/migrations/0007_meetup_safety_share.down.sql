-- Reverses 0007_meetup_safety_share.up.sql.
--
-- Loses the record of which contacts were notified. The notifications
-- themselves already went out (they are SMS/email, not rows), so this only
-- discards the app's ability to show the user what it did — it cannot
-- un-send anything.
DROP TABLE IF EXISTS meetup.safety_share;
