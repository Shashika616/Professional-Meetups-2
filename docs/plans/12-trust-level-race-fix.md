# Plan 12 — fix the trust-level lost-update race (gap-tracker #17)

## The bug

Six methods on `auth`'s `UserRepository` share one shape: the service layer
reads a user row, builds a `hypothetical` copy reflecting one field change,
computes `trust_level` from that copy in Go (`computeTrustLevel`), then calls
an `Update*` method that writes the new field **and** the precomputed
`trust_level` in a single UPDATE:

- `UpdatePhoneNumber` (`verification.go` `VerifyPhoneCode`)
- `UpdatePersonalEmail` (`verification.go` `VerifyPersonalEmailCode`)
- `UpdatePersonalDetails` (`verification.go` `SubmitPersonalDetails`)
- `UpdateWorkEmailVerified` (`verification.go` `VerifyCorporateEmailCode`)
- `UpdateLinkedInSub` (`identity_resolution.go`, LinkedIn-linking branch)
- `ClearGuestFlag` (`identity_resolution.go`, Apple/Google-linking branch)

There is no transaction and no row lock spanning the read and the write. If
two of these calls for the *same user* are in flight at once (realistic: a
user clicking through the Level 2 checklist — phone, then personal email,
then personal details — quickly, or a slower request racing a faster one),
both read the same starting row, both compute `trust_level` from a snapshot
that only reflects their own field, and whichever commits second overwrites
`trust_level` with a value that doesn't account for the other's
already-committed change. Net effect: a user completes every Level 2 field
but the stored `trust_level` silently stays at 1, and nothing ever
recomputes it afterward — they're stuck below the intended trust level with
no error and no obvious symptom pointing at the cause.

This is the same bug *class* the meetups-completed cache guard already hit
once (fixed there by comparing values instead of timestamps) — never
generalized to these six call sites, which need a different fix since
`trust_level` depends on a computed combination of fields, not one
monotonic counter.

The repository interface's own doc comment (`repository.go:148-155`)
explains why the field-write and the trust-level-write are combined into one
statement — to avoid *a different* race (a separate recompute step going
stale between two statements). It does not address this one: the snapshot
feeding the single statement can itself already be stale before that
statement runs.

## The fix

Lock the user row for the duration of the read-compute-write, using the
same transaction idiom the codebase already uses in
`refresh_tokens_postgres.go`'s `Rotate` (`pool.Begin` → `defer tx.Rollback`
→ `r.q.WithTx(tx)` → ... → `tx.Commit`). Concretely:

**1. New sqlc query** (`repository/queries/users.sql`), alongside the
existing `GetUserByID`:

```sql
-- name: GetUserByIDForUpdate :one
SELECT * FROM auth.users WHERE id = $1 FOR UPDATE;
```

Regenerate sqlc output the usual way for this repo.

**2. Change the six repository method signatures** from taking a
precomputed `trustLevel int` to taking a `recomputeTrustLevel
func(User) int` callback, e.g.:

```go
// Before:
UpdatePhoneNumber(ctx context.Context, userID, phoneNumber string, trustLevel int) (User, error)

// After:
UpdatePhoneNumber(ctx context.Context, userID, phoneNumber string, recomputeTrustLevel func(User) int) (User, error)
```

Same change for `UpdatePersonalEmail`, `UpdatePersonalDetails`,
`UpdateWorkEmailVerified`, `UpdateLinkedInSub`, `ClearGuestFlag`.

**3. Rewrite each Postgres implementation** to lock-then-recompute-then-write
inside one transaction. `UpdatePhoneNumber` as the template:

```go
func (r *postgresUserRepository) UpdatePhoneNumber(ctx context.Context, userID, phoneNumber string, recomputeTrustLevel func(User) int) (User, error) {
	parsed, err := uuid.Parse(userID)
	if err != nil {
		return User{}, fmt.Errorf("repository: invalid user id %q: %w", userID, apperror.ErrInvalidInput)
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return User{}, fmt.Errorf("repository: begin update-phone-number transaction: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op once committed
	qtx := r.q.WithTx(tx)

	// Lock the row before computing anything — this is what closes the
	// race: a concurrent verification step for the same user either
	// already committed (so this read sees it) or is blocked until this
	// transaction commits (so it will see this write).
	lockedRow, err := qtx.GetUserByIDForUpdate(ctx, parsed)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return User{}, fmt.Errorf("repository: user %q: %w", userID, apperror.ErrNotFound)
		}
		return User{}, fmt.Errorf("repository: lock user for phone number update: %w", err)
	}
	locked := userFromRow(lockedRow)
	// Reflect this statement's own field write in the snapshot handed to
	// the callback, same reasoning as afterVerification's is_guest fix —
	// the computed trust level must account for every change this
	// statement is about to make, not just what's already committed.
	locked.PhoneNumber = phoneNumber
	trustLevel := recomputeTrustLevel(locked)

	row, err := qtx.UpdateUserPhoneNumber(ctx, sqlcgen.UpdateUserPhoneNumberParams{
		ID:          parsed,
		PhoneNumber: textOrNull(phoneNumber),
		TrustLevel:  int16(trustLevel),
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return User{}, fmt.Errorf("repository: phone number already verified on a different account: %w", apperror.ErrConflict)
		}
		return User{}, fmt.Errorf("repository: update user phone number: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return User{}, fmt.Errorf("repository: commit update-phone-number transaction: %w", err)
	}

	updated := userFromRow(row)
	r.publishProfileUpdated(ctx, updated)
	return updated, nil
}
```

Apply the identical shape to the other five methods — lock via
`GetUserByIDForUpdate`, set whatever field(s) that method is about to write
onto the locked snapshot, call `recomputeTrustLevel(locked)`, write inside
the same `qtx`, commit, then publish exactly as today. `UpdatePersonalEmail`
and `UpdatePersonalDetails` set their own fields the same way `afterVerification`
callers already do today (see current bodies for the exact field list —
`PersonalEmail`, or `LegalName`+`Address`). `UpdateWorkEmailVerified` sets
`CompanyDomain`/`WorkEmailVerified`/`CompanyName`. `UpdateLinkedInSub` sets
`LinkedInSub`. `ClearGuestFlag` sets nothing extra (it only flips
`IsGuest`, which the callback's own `afterVerification` already handles).

Keep `publishProfileUpdated` outside the transaction, unchanged — ADR-001
§4 is explicit that the synchronous in-process publish must happen after
commit, not inside the transaction.

**4. Update the five call sites** (`verification.go` ×4,
`identity_resolution.go` ×2 — `UpdateLinkedInSub` and `ClearGuestFlag` are
both in that file) to pass a closure instead of a precomputed int. Example,
`VerifyPhoneCode`:

```go
// Before:
hypothetical := afterVerification(user)
hypothetical.PhoneNumber = req.Target
persisted, err := s.users.UpdatePhoneNumber(ctx, req.UserID, req.Target, computeTrustLevel(hypothetical))

// After:
persisted, err := s.users.UpdatePhoneNumber(ctx, req.UserID, req.Target, func(u repository.User) int {
	return computeTrustLevel(afterVerification(u))
})
```

The `user, err := s.users.GetByID(ctx, req.UserID)` read immediately before
this becomes dead — delete it (its only purpose was building
`hypothetical`, which the repository now builds itself from the locked
row). Same deletion applies to all five other call sites: `identity_resolution.go`'s
`user, err := s.users.GetByID(ctx, userID)` at line 130 currently feeds both
the `UpdateLinkedInSub` branch and the `!user.IsGuest` early-return check in
the `ClearGuestFlag` branch below it — that early-return check is a
short-circuit optimization (skip the write if nothing would change), not
part of the race-safety fix, so keep that one `GetByID` call for the
early-return check but stop using its result to build `hypothetical` for
either branch.

**5. Update the interface doc comments** at `repository.go:148-179` — they
currently describe the "compute in Go, write in one statement" design as
if it fully closes the race. Replace the relevant sentences with something
like: "trustLevel is recomputed from the row as locked at write time
(`SELECT ... FOR UPDATE` inside a transaction), not from a snapshot read
before the call — this is what prevents two concurrent verification steps
for the same user from each computing off a stale snapshot and the later
write silently under-stamping trust_level (gap-tracker #17)."

**Correction (2026-09-09, before handoff) — three more test call sites pass
a literal `int` and will fail to compile once the signature changes.**
Checked directly: `backend/internal/modules/auth/identity_resolution_test.go:268`
and `:291`, and `backend/internal/modules/auth/service_test.go:543`, all
call `deps.users.UpdatePersonalEmail(ctx, id, email, 1)` /
`(..., 0)` — a bare int literal in the fourth argument position, seeding
test fixtures directly through the fake repository rather than through the
service layer. These are not part of the bug (they're test setup, not
production call sites) but they WILL fail to compile once
`UpdatePersonalEmail`'s signature changes to
`func(User) int`. Fix each by replacing the literal with a callback
returning it: `func(repository.User) int { return 1 }` (or `0`, matching
whatever the original literal was). `go build`/`go test` will surface
these three plus any others not listed here — treat the compiler's own
error list as the authoritative check, not this list.

**6. Update `fakes_test.go`'s six fake methods** to match the new
`func(User) int` signature — each fake already has the row in hand
(`f.get(userID)` or equivalent), so the fix there is simpler: call the
passed-in `recomputeTrustLevel` with the fake's own current row (plus
whatever field it's about to set) instead of accepting a precomputed int.
This is what makes the existing unit tests actually exercise the new
call-site closures rather than just recompiling against a changed
signature.

**7. Add one new regression test** in the auth package's test file for
`VerifyPhoneCode`/`VerifyPersonalEmailCode`/`SubmitPersonalDetails` (or a
new dedicated test file) that simulates the race directly against the fake:
have the fake's `GetByIDForUpdate`-equivalent (or just its existing
in-memory row) reflect a *second* field already being set before the
callback runs, and assert the returned `trust_level` accounts for both
fields — i.e. assert the fix actually produces the higher trust level in
the scenario the bug used to under-stamp. A fake repository can't exercise
real Postgres row-locking, so this test proves the recompute-from-current-state
logic is correct; it doesn't (and can't, without a real Postgres integration
test) prove the lock itself serializes concurrent transactions — call that
out as a known test-depth limit if a reviewer asks, don't claim more than
the fake can prove.

## Scope note

Gap-tracker #17 named only the three Level-2 verification methods. This
plan fixes all six methods that share the identical bug shape
(`UpdateWorkEmailVerified`, `UpdateLinkedInSub`, `ClearGuestFlag` included)
in the same pass, since it's the same mechanical transformation and leaving
three near-identical unfixed instances sitting next to the fixed ones would
just be gap #17b waiting to be found on the next sweep.

## Out of scope

No API/RPC shape changes, no migration beyond the one new sqlc query (which
needs no schema change — `FOR UPDATE` is a query-time lock, not a DDL
change), no frontend changes. This is a backend-only, same-behavior-under-
no-contention fix.
