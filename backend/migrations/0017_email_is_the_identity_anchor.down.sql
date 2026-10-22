-- Back to case-sensitive uniqueness. Same order as the up: build the old
-- index before dropping the new one, so uniqueness is never absent.
--
-- This can fail where the up succeeded, and that is correct: if two
-- addresses differing only in case were created while the lower() index was
-- in force, they are legitimate rows under it and cannot both exist under a
-- case-sensitive unique index. Resolve the pair by hand before rolling back.
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_personal_email
  ON auth.users (personal_email)
  WHERE personal_email IS NOT NULL;

DROP INDEX IF EXISTS auth.idx_users_personal_email_lower;
