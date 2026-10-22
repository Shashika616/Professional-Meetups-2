-- Reverses 0021. Refuses rather than inventing coordinates for the rows
-- that legitimately have none: an SOS triggered without a fix is exactly
-- the event worth keeping, and back-filling it with 0,0 would put a point
-- in the Gulf of Guinea into a safety audit trail.
--
-- If a rollback really is needed, decide what those rows should become
-- (deleting them is usually wrong — they are safety records) and then run
-- this.

DO $$
DECLARE
    without_location bigint;
BEGIN
    SELECT count(*) INTO without_location
      FROM auth.sos_events
     WHERE latitude IS NULL OR longitude IS NULL;

    IF without_location > 0 THEN
        RAISE EXCEPTION
            'cannot restore NOT NULL on auth.sos_events location: % row(s) record an SOS triggered without a location fix. These are real safety events; decide what to do with them deliberately rather than back-filling coordinates.',
            without_location;
    END IF;
END $$;

ALTER TABLE auth.sos_events ALTER COLUMN latitude SET NOT NULL;
ALTER TABLE auth.sos_events ALTER COLUMN longitude SET NOT NULL;
