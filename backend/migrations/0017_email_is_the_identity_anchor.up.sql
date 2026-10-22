-- Email becomes the thing that says "this is the same person" (2026-10-07).
--
-- # WHAT CHANGES
--
-- personal_email was already unique. It was unique CASE-SENSITIVELY, which
-- is not the same thing as being an identity:
--
--   ada@gmail.com  and  Ada@Gmail.com
--
-- are one mailbox at every mail host in use, and were two accounts here.
-- Someone who signed up with the capitalised form and later signed in with
-- the lower-case one got a second, empty account and no way to tell why.
-- That is the exact failure this column is now being asked to prevent, so
-- the index has to agree with what an address means rather than with how it
-- was typed.
--
-- The expression here and auth.NormalizeEmail in Go must stay in step: the
-- Go side lowercases and trims before every write and every lookup, this
-- index lowercases what is stored. Trimming is deliberately NOT in the
-- index — a stored address with surrounding space is a bug on the write
-- path, and hiding it here would make that bug invisible rather than fixed.
--
-- # WHY A UNIQUE INDEX AND NOT A BLOOM FILTER
--
-- A Bloom filter was considered for "does this email already exist" at
-- millions of rows. It is the wrong tool twice over. It answers with false
-- positives, so a hit still costs the real lookup — the index is needed
-- regardless. And it enforces nothing: two signups racing with the same
-- address both pass a membership test and both insert. The unique index is
-- what actually makes a duplicate impossible, and having it makes the
-- lookup a four-page btree descent, which no cache in front of it would
-- meaningfully beat.
--
-- # SAFETY OF THIS MIGRATION
--
-- Checked against production before writing it: zero addresses collide
-- case-insensitively today, so the new index builds without conflict. If
-- that ever stops being true the CREATE fails and the migration aborts
-- before the old index is gone, because the new one is built FIRST.

-- Build the replacement before dropping the incumbent, so a collision
-- leaves the old guarantee intact rather than dropping uniqueness and then
-- failing to restore it.
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_personal_email_lower
  ON auth.users (lower(personal_email))
  WHERE personal_email IS NOT NULL;

DROP INDEX IF EXISTS auth.idx_users_personal_email;

-- Plain CREATE INDEX, not CONCURRENTLY, matching every other migration in
-- this directory: golang-migrate runs each file in a transaction and
-- CONCURRENTLY cannot run inside one. auth.users is small (tens of rows at
-- the time of writing) so the SHARE lock is milliseconds; revisit if that
-- stops being true.
