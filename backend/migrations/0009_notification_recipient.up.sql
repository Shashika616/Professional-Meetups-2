-- The in-app notification list (Profile → Notifications) needs to answer
-- "what was sent to ME", and notification_outbox could not: it stores
-- resolved fcm_tokens, deliberately, because the NOTIFICATION module has no
-- database and cannot map a user to devices (see 0003's own comment).
--
-- But the MEETUP module, which writes every one of these rows, does know the
-- recipient — queueNotification takes a userID and resolves that user's
-- tokens right there. The id was simply never stored. This adds it.
--
-- Nullable, and no backfill: rows written before this migration genuinely do
-- not know their recipient, and inventing one would be worse than showing a
-- slightly shorter history for a week. They age out on their own via the
-- existing 7-day retention.
ALTER TABLE meetup.notification_outbox
    ADD COLUMN user_id UUID;

-- The list query is "this user's rows, newest first, within the retention
-- window". Partial on user_id IS NOT NULL so the pre-migration rows — and
-- any future fan-out row that genuinely has no single recipient — cost
-- nothing to carry.
CREATE INDEX idx_notification_outbox_user_recent
    ON meetup.notification_outbox (user_id, created_at DESC)
    WHERE user_id IS NOT NULL;
