Fix a real correctness bug: a lost-update race on `trust_level` in the auth
module. Full design is in `docs/plans/12-trust-level-race-fix.md` — read it
first, it has the exact code shape. Summary below.

**The bug.** Six `UserRepository` methods each write `trust_level` using a
value the *service layer* precomputed from a `GetByID` read taken before the
write, with no transaction or lock spanning the read and write:
`UpdatePhoneNumber`, `UpdatePersonalEmail`, `UpdatePersonalDetails`,
`UpdateWorkEmailVerified` (all in `backend/internal/modules/auth/repository/`,
Postgres impl in `users_postgres.go`), `UpdateLinkedInSub`, `ClearGuestFlag`.
Two concurrent verification steps for the same user (e.g. clicking through
the Level 2 checklist quickly) can each compute `trust_level` off a stale
snapshot; whichever write commits second silently under-stamps
`trust_level`, and nothing ever recomputes it afterward.

**The fix, in order:**

1. Add `GetUserByIDForUpdate` to `repository/queries/users.sql`
   (`SELECT * FROM auth.users WHERE id = $1 FOR UPDATE;`), regenerate sqlc.

2. Change all six `UserRepository` interface methods
   (`repository/repository.go`) to take `recomputeTrustLevel func(User) int`
   instead of `trustLevel int`.

3. Rewrite all six Postgres implementations (`users_postgres.go`) to: begin
   a transaction (`r.pool.Begin`, `defer tx.Rollback`, `qtx := r.q.WithTx(tx)`
   — same idiom already used in `repository/refresh_tokens_postgres.go`'s
   `Rotate`), call `qtx.GetUserByIDForUpdate` to lock the row, set onto that
   locked snapshot whatever field(s) this method is about to write (mirror
   what the current Go code sets on `hypothetical` today), call
   `recomputeTrustLevel(locked)`, run the existing UPDATE via `qtx`, then
   `tx.Commit`. Keep `publishProfileUpdated` after commit, outside the
   transaction, unchanged. Full worked example for `UpdatePhoneNumber` is in
   the plan doc — follow it exactly for that method, then apply the same
   shape to the other five.

4. Update the five call sites to pass a closure instead of a precomputed
   int, e.g. `VerifyPhoneCode` in `verification.go`:
   ```go
   persisted, err := s.users.UpdatePhoneNumber(ctx, req.UserID, req.Target, func(u repository.User) int {
   	return computeTrustLevel(afterVerification(u))
   })
   ```
   Delete the now-dead `user, err := s.users.GetByID(...)` + `hypothetical :=
   ...` lines at each of the four `verification.go` call sites. In
   `identity_resolution.go`, `UpdateLinkedInSub`'s call site loses its
   `GetByID`+`hypothetical` the same way; `ClearGuestFlag`'s call site keeps
   its `GetByID` only because the result also feeds the `!user.IsGuest`
   early-return check right above it — stop using that result to build
   `hypothetical`, but don't delete the read itself.

5. Update the doc comments on the six interface methods in `repository.go`
   (currently around lines 148-185) to describe the new locking behavior
   instead of claiming the old single-statement design already closed this
   race. Exact replacement language is in the plan doc.

6. Update the six fake implementations in `fakes_test.go` to accept
   `func(User) int` and call it with the fake's own current row (plus the
   field(s) being set) instead of accepting a precomputed int — this makes
   existing tests actually exercise the new closures.

6a. Three more test call sites pass a bare int literal directly to
   `UpdatePersonalEmail` and will fail to compile once its signature
   changes: `identity_resolution_test.go:268`, `identity_resolution_test.go:291`,
   `service_test.go:543`. Replace each literal (e.g. `1` or `0`) with
   `func(repository.User) int { return 1 }` (matching the original value).
   These are test fixture setup, unrelated to the bug itself — just fix the
   call shape.

7. Add one new regression test exercising the fix: simulate a second field
   already being set on the fake's row before the callback runs, and assert
   the resulting `trust_level` accounts for both fields. Note in a comment
   that a fake can't prove the Postgres row lock itself serializes
   concurrent transactions — this test proves the recompute-from-current-
   state logic only.

**Constraints:**
- No API/RPC shape changes, no frontend changes.
- No schema migration needed — `FOR UPDATE` is query-time, not DDL.
- Don't touch `UpdateFullName`, `UpdateLastKnownLocation`,
  `UpsertRatingCache`, `UpsertMeetupsCompletedCache` — none of them compute
  `trust_level` and none have this bug.
- Run `go build ./...` and `go test ./internal/modules/auth/...` when done
  and report the actual output, not just "should work."

Report back exactly what you changed, file by file, so it can be verified
against source — don't summarize as "fixed the race condition," list the
actual diffs.
