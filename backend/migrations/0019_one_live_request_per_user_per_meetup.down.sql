-- Reverses 0019, but ONLY when the data still fits the old constraint.
--
-- The old UNIQUE (meetup_id, requester_id, status) is STRICTER than the
-- partial index in one direction: it forbids two rows sharing a dead
-- state — two 'rejected' rows for the same person on the same meetup, two
-- 'withdrawn' rows, and so on. Those rows are legal under 0019 and the
-- application creates them on purpose (that is the re-request flow). So a
-- database that has been running on 0019 for any length of time will
-- usually contain rows the old constraint cannot accept.
--
-- A plain ALTER TABLE ... ADD CONSTRAINT there fails with a bare 23505
-- naming one arbitrary row, which tells whoever is mid-rollback nothing
-- about what to do. This refuses first, with the count and an example, so
-- the decision — delete the duplicate history, or stay on 0019 — is made
-- deliberately rather than discovered.
--
-- The new index is dropped only after the old constraint is back, mirroring
-- the up migration's ordering so neither direction has an unprotected gap.

DO $$
DECLARE
    offending bigint;
    sample    text;
BEGIN
    SELECT count(*), min(meetup_id::text || ' / ' || requester_id::text || ' / ' || status::text)
      INTO offending, sample
      FROM (
        SELECT meetup_id, requester_id, status
          FROM meetup.meetup_requests
         GROUP BY meetup_id, requester_id, status
        HAVING count(*) > 1
      ) duplicates;

    IF offending > 0 THEN
        RAISE EXCEPTION
            'cannot restore UNIQUE (meetup_id, requester_id, status): % duplicate (meetup, requester, status) group(s) exist, e.g. %. These rows are legal under migration 0019 (a person may be rejected or withdraw more than once on one meetup) and the old constraint cannot hold them. Resolve the duplicates deliberately before rolling back, or stay on 0019.',
            offending, sample;
    END IF;
END $$;

ALTER TABLE meetup.meetup_requests
    ADD CONSTRAINT meetup_requests_meetup_id_requester_id_status_key
    UNIQUE (meetup_id, requester_id, status) DEFERRABLE INITIALLY IMMEDIATE;

DROP INDEX IF EXISTS meetup.uq_meetup_requests_one_live_per_user;
