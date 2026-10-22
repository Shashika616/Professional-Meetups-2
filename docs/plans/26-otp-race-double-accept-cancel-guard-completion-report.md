# Plan 26 completion report — V-1, V-2, V-10

Date: 2026-10-08. Working tree only; nothing committed, nothing deployed. No migrations.

Source: `docs/security-review-2026-10-01.md` (V-1, V-2, V-10), tracker #51, #52, #59, #72.

## V-1 — the OTP attempt cap now bounds guesses, not turns

The cap was check-then-act: read the row, test `Attempts >= 5` in Go, compare the
code, increment only on a mismatch. Every concurrent guess read the same
pre-increment value, so five attempts meant "five if you take turns" and nothing
at all otherwise.

The order is reversed. An attempt is spent atomically first, and only then is the
code looked at.

New queries in `auth/repository/queries/verification_codes.sql`:

- `ClaimVerificationAttempt` / `ClaimVerificationAttemptByTarget` —
  `UPDATE ... SET attempts = attempts + 1 WHERE <key> AND attempts <
  sqlc.arg(max_attempts)::smallint AND expires_at > now() RETURNING *`. Postgres
  serialises concurrent updates of one row and re-evaluates the predicate against
  the committed value, so exactly `max_attempts` of them can ever succeed. The
  cap is a parameter so `otpMaxAttempts` stays the only place it is written down.
- `ConsumeVerificationCode` / `ConsumeVerificationCodeByTarget` —
  `DELETE ... WHERE <key> AND code_hash = $x RETURNING *`. The old success path
  was an unconditional delete whose result nobody read, which is how one correct
  code could be spent twice.

Service flow in `verifyAndConsumeCode` (verification.go) and
`verifyAndConsumeTargetKeyedCode` (service.go): claim → compare → consume. Every
purpose goes through one of the two, `account_claim` included.

**Messages are unchanged.** The atomic claim collapses "no row", "expired" and
"cap spent" into one zero-row answer, so `explainUnclaimableAttempt` (and its
target-keyed twin) reads the row back to pick the right sentence. That read
decides wording only and can never hand back an attempt.

**One deliberate difference from the old code, and it is a fix rather than an
oversight.** The old "too many attempts" branch deleted the row. Doing that in
the explain path would be a live bug: it is now reachable while other requests
are mid-comparison — that is what a spent cap under parallel load means — and
deleting the row under them would make their consume find nothing and report a
correct code as invalid. The row is still cleared by the guess that spends the
last attempt, and on expiry, so nothing lingers.

**Also deliberate:** a mismatched `target` now costs an attempt, because the check
moved onto the claimed row. It is a failed verification attempt, and attempts
could already be burned with wrong codes, so nothing new is exposed.

**Not changed, still open:** a resend resets `attempts` to 0 (tracker #13). The
real bound is still five guesses per code times however many codes the cooldown
allows. Out of scope here and unchanged by this work.

## V-2 — double accept

Three changes, in `meetup_requests_postgres.go` and
`queries/meetup_requests.sql`:

1. The transaction locks the **meetup** first, then re-reads the request with the
   new `GetMeetupRequestByIDForUpdate` and checks the status on that locked row.
   The first unlocked read is kept for one purpose only — learning which meetup to
   lock — and its status is explicitly not trusted. Lock order is
   meetups-then-requests, matching every other transaction that touches both.
2. `AcceptMeetupRequest` gained `AND meetup.meetup_requests.status = 'pending'`.
   Zero rows was already mapped to `ErrConflict`.
3. Full-ness comes from a fresh `CountAcceptedRequests` after the update instead
   of `acceptedCount + 1`, so a double accept cannot manufacture a seat.

A guard against a thing that cannot happen was added alongside: the request's
`meetup_id` is compared with the locked meetup's id, because the value that chose
which row to lock came from the unlocked read, and a lock on the wrong row
protects nothing.

**Reject, withdraw and cancel-pending were checked (plan task 2.4) and were
already correct.** `RejectMeetupRequest` carries `status = 'pending'`,
`WithdrawMeetupRequest` carries `status IN ('pending','accepted')` (right:
an accepted place can be withdrawn), `CancelPendingMeetupRequest` carries
`status = 'pending'`. No change made.

## V-10 — cancel guard

`CancelMeetup` gained `AND status IN ('open', 'full')`.

**No window check, and the plan asked for this to be decided and stated.**
`CloseMeetup` already owns the past-window case (`status IN ('open','full') AND
now() >= window_start` → completed), and a host whose window has started but
whose meetup is still open has a legitimate reason to cancel — nobody came, or
they cannot make it. The auto-close sweep moves those to completed and the status
guard then protects them. `window_end > now()` would block the honest case and
protect nothing the status does not already cover.

Zero rows is no longer reported as not-found. `explainFailedCancel` re-reads on
the same transaction and distinguishes: gone → not-found; not the caller's →
not-found (so id-guessing cannot tell "not yours" from "does not exist"); wrong
state → conflict naming the state.

**Notifications on a rejected cancel: confirmed none.** They are queued by a
callback invoked after the UPDATE, inside the same transaction. The early return
on the failure path means the callback never runs and the transaction rolls back.
Asserted by counting outbox rows before and after in both rejection tests.

## Task 4 — the Level 2 decision, pinned

`TestComputeTrustLevel_ProviderVerifiedEmailCountsTowardLevel2` in
`auth/trustlevel_test.go`. A user with LinkedIn, phone, legal name and a
provider-sourced `PersonalEmail` is Level 2 with no OTP step; the same user
without the address is Level 1, so the rung is load-bearing rather than
incidentally satisfied. No behaviour change.

## Test fixtures — unchanged and proven

`ALLOW_TEST_OTP_BYPASS`, `TEST_OTP_BYPASS_PHONES`, `TEST_OTP_BYPASS_EMAILS` and
the seeded `@meetups.test` accounts are untouched. The verify-side allowlist
lives inside `otpMatches`, which the rework now calls on the row returned by the
atomic claim rather than on an unlocked read, so
`TestTestOTPBypassEmails_StillWorkThroughTheReworkedPath_Integration` pins:

- an allowlisted address still verifies with `123456`;
- a non-allowlisted address does not, and its real code still works on the same
  code row (so the refused `123456` spent an attempt, not the whole code);
- `account_claim` is still not covered by the allowlist, as `TESTING-NOTES.md`
  records.

## Tests, and that they fail on the old code

Every test below was run against a deliberately reverted version of the code it
covers. Results:

| Mutation | Result |
|---|---|
| Attempt cap made ineffective (claim with a huge max) | **FAILS** — "40 of 50 parallel guesses were actually compared, want at most 5" |
| `ConsumeByTarget` reverted to the old unchecked delete | **FAILS** — "second consume returned nil, want ErrNotFound" |
| V-2: both the Go re-read and the SQL predicate removed (the old code) | **FAILS** — meetup went to `full`, bystander auto-rejected, accept-after-reject succeeded |
| V-2: SQL predicate alone removed | passes — the Go re-read is the primary guard and the predicate is defence in depth, which is what the plan asked for |
| V-10: status guard removed | **FAILS** — "cancel a completed meetup: error = nil" and status became `cancelled` |

New files:

- `internal/modules/auth/otp_attempt_race_integration_test.go` — 50 parallel wrong
  guesses (at most `maxAttempts` compared); parallel correct submissions on the
  email-login path; a correct code refused after the cap is spent by parallel
  guesses; deterministic repository-level claim/consume semantics; the bypass
  fixtures.
- `internal/modules/meetup/accept_cancel_guard_integration_test.go` — concurrent
  double accept; accept after reject, after a pending cancel, and after
  withdrawing an accepted place; the four cancel-guard cases.
- `internal/gateway/handlers/delete_account_authz_test.go` — see "Asked for
  separately" below.

**One honest caveat on a test.** "Two correct submissions, one success" is weak as
a race test and I am saying so rather than leaving it to be discovered: once the
winner's DELETE commits, later callers fail at the *claim* instead of the
consume, so the window in which the unchecked delete is observable is
microseconds wide. Measured: a deliberately broken consume **passes** that test.
It also passed when written against phone verification, because that path writes
the user row and concurrent calls serialise on it, so "exactly one succeeded" was
true for reasons unrelated to the code. The single-use guarantee is therefore
pinned by the deterministic repository-level test, which a broken consume does
not survive; the parallel test is kept as an end-to-end guard, not as the proof.

## Performance and locking

Every query added or changed is index-backed — checked with `EXPLAIN` against the
test database, no sequential scans:

| Query | Plan |
|---|---|
| `ClaimVerificationAttempt` | Index Scan, `idx_verification_codes_user_id` |
| `ClaimVerificationAttemptByTarget` | Index Scan, `idx_verification_codes_signup_target` |
| `ConsumeVerificationCodeByTarget` | Index Scan, `idx_verification_codes_signup_target` |
| `CountAcceptedRequests` (the extra call V-2 adds) | **Index Only Scan**, `idx_meetup_requests_meetup` — never touches the heap |
| `GetMeetupRequestByIDForUpdate`, `CancelMeetup` | Index Scan, primary key |

No new index was needed. Round trips: V-1's happy path goes from three statements
to two, and a locked-out caller now costs one instead of three. V-1 removes
application-level read-modify-write rather than adding a lock. V-2 adds one row
lock, but inside a transaction that already held the meetup's, in the
meetups-then-requests order the rest of the codebase uses, so no new wait cycle is
possible. V-10 adds a predicate to an existing UPDATE (free) and a read only on
the failure path.

## Asked for separately: who can delete an account

Verified and pinned, no code change needed. `DELETE /v1/users/me` accepts no user
identifier in any form — no path segment, no query parameter, no body field. The
id comes from `middleware.UserIDFromContext`, populated only by `middleware.Auth`
after `verifier.Verify` validates the signature; no header influences identity;
there is no admin or impersonation route. Cloud Run publishes only the gateway's
port 8080 while the monolith listens on `localhost:9090`, and the monolith's own
`DeleteAccount` RPC — which does take a `user_id` — additionally requires
`INTERNAL_GRPC_SHARED_SECRET`.

`delete_account_authz_test.go` pins five cases, including the one that guards the
future: a request whose body and query both name `victim-1`, sent with
`attacker-1`'s token, must delete `attacker-1`. That fails the moment anyone
teaches this route to read an id from the request.

## Found but not fixed

- **#13, attempt reset on resend.** A new code sets `attempts = 0`, so the bound
  is per code rather than absolute. Pre-existing, documented, out of scope.
- **No target-keyed verify limiter** (V-1's "related" note, #53). The atomic cap
  bounds guesses per code; it does not bound codes. The send side has a
  one-minute cooldown, the verify side has nothing of its own.
- **V-11, join is not atomic with meetup state.** Adjacent to V-2 and the same
  shape (open check outside the transaction, no recheck on insert). Untouched —
  the plan scoped it out.
- **`IncrementAttempts` / `IncrementAttemptsByTarget` are now dead** on the
  production paths. Left in place: they are still part of the repository
  interface and its fakes, and removing them is a wider edit than this plan
  wanted. Worth deleting in a follow-up so nobody reaches for the unguarded
  increment again.

## Verification

```
cd backend && go build ./... && go vet ./... && go test ./...
go test -race -count=20 ./internal/modules/auth/... ./internal/modules/meetup/...
```

Phase 1 — `build`, `vet`, `go test ./...`: clean, 22 packages ok, 0 failures.

Phase 2 — `-race -count=20`, **exit 0, zero data races**:

```
ok  .../internal/modules/auth              669.662s
ok  .../internal/modules/auth/email        201.403s
ok  .../internal/modules/auth/identity      12.580s
ok  .../internal/modules/auth/linkedin       1.131s
ok  .../internal/modules/auth/repository     1.049s
ok  .../internal/modules/auth/sms            1.081s
ok  .../internal/modules/meetup           1371.394s
```

**A first attempt at phase 2 failed, and the cause was environmental, not the
code — recorded here so the log is not mistaken for a real regression later.**
Docker Desktop quit partway through, so the integration tests lost their
database mid-run. The signature was unmistakable in hindsight: zero data races,
the auth package passing all 20 iterations, and then a cascade of meetup
failures at 0.01-0.04s each (setup failing, not assertions) plus one 16s
timeout. Postgres was found down immediately afterwards, and a re-run returned
`ok` in 1.17s because every integration test skipped. With the container back
up, the identical command passes as above.

The integration tests need the local Postgres (`docker compose up -d postgres`);
`db.EnsureTestDatabase` keeps them in `monolith_db_test`, and `monolith_db` was
confirmed unchanged afterwards (20 users before and after, schema 18).

Frontend, for the UI review items in the same working tree: 725 tests pass and
`flutter analyze --fatal-infos` is clean.

## Deploy notes

No migrations in this plan. Migrations 0017 and 0018 are still pending from
ADR-009 and are independent; if they ship together, apply the migrations first.
