DROP INDEX IF EXISTS meetup.idx_notification_outbox_user_recent;
ALTER TABLE meetup.notification_outbox DROP COLUMN IF EXISTS user_id;
