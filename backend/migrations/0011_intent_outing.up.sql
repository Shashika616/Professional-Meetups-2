-- 0010 added this intent under the label 'events'. That word is also the
-- name of the app's Events tab, and the label leaks into places a user can
-- read (browse filters, notification copy paths), so the wire value itself
-- is renamed rather than papered over in the UI. RENAME VALUE rewrites the
-- label in place — every existing row keeps its meaning, no data is touched.
ALTER TYPE meetup.intent_type RENAME VALUE 'events' TO 'outing';
