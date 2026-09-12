-- PostgreSQL has no DROP VALUE for enums. Reversing this means rebuilding
-- the type without the label, which is only safe if nothing references it —
-- so this refuses to run while any meetup still uses 'events' rather than
-- silently destroying rows. Delete or re-intent those meetups first.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM meetup.meetups WHERE intent = 'events') THEN
    RAISE EXCEPTION 'cannot drop intent ''events'': meetup.meetups still has rows using it';
  END IF;
END $$;

ALTER TYPE meetup.intent_type RENAME TO intent_type_old;
CREATE TYPE meetup.intent_type AS ENUM ('coffee', 'lunch', 'networking', 'mentorship', 'ride_share', 'dating');
ALTER TABLE meetup.meetups
  ALTER COLUMN intent TYPE meetup.intent_type USING intent::text::meetup.intent_type;
DROP TYPE meetup.intent_type_old;
