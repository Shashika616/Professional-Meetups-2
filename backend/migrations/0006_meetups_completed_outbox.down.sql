-- Indexes go with the table, same as 0003's down.
--
-- Reversing this loses any not-yet-processed recompute intents. That is
-- recoverable in a way 0003's is not: the counts are derived from
-- meetup.meetups / meetup.meetup_requests, which are untouched, so
-- reinstating the synchronous recompute (or replaying any later completion
-- for the same users) rebuilds them. Nothing is permanently lost.
DROP TABLE IF EXISTS meetup.meetups_completed_outbox;
