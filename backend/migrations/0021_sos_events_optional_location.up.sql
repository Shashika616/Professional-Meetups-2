-- Tracker #78 / review finding N-D2.
--
-- sos_events.latitude and .longitude were NOT NULL, which is the audit
-- trail insisting on something the client could not always supply. That
-- constraint is part of why SOS refused to send at all without a GPS fix:
-- there was nowhere to record the event.
--
-- An SOS with no location is a real event and the one most worth keeping
-- — it means somebody pressed the button while the device could not say
-- where they were. NULL is the honest representation; 0,0 is a real
-- place in the Gulf of Guinea and would have been a lie in the audit
-- trail as surely as in the alert.

ALTER TABLE auth.sos_events ALTER COLUMN latitude DROP NOT NULL;
ALTER TABLE auth.sos_events ALTER COLUMN longitude DROP NOT NULL;
