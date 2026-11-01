DROP TABLE IF EXISTS meetup.billing_outbox;
DROP INDEX IF EXISTS meetup.idx_meetups_host_creation_key;
ALTER TABLE meetup.meetups DROP COLUMN IF EXISTS charge_hold_id;
ALTER TABLE meetup.meetups DROP COLUMN IF EXISTS creation_key;
-- NOT VALID: meetups created with 21-30 places while this was widened stay
-- as they are; only new rows are held to the old limit.
ALTER TABLE meetup.meetups DROP CONSTRAINT IF EXISTS meetups_capacity_check;
ALTER TABLE meetup.meetups ADD CONSTRAINT meetups_capacity_check CHECK (capacity BETWEEN 1 AND 20) NOT VALID;
