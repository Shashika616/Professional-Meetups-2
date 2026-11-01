# 29A completion report: billing foundations

Date: 2026-10-24. Working tree only: nothing committed, pushed, deployed or run
against production. Migrations 0025-0028 were applied only to local scratch and
test databases.

`docs/plans/29-decisions.md` does not exist, so decisions D1-D11 use the plan's
defaults.

## Finish checks

| Check | Result |
|---|---|
| `go vet ./...` | clean |
| `gofmt -l` (excluding generated proto) | clean |
| `golangci-lint run ./...` (v2.12.2, as CI) | 0 issues. One run reported SA5011 in the untouched `auth/repository/convert_test.go`; it came from a stale lint cache and disappeared after `golangci-lint cache clean`. The same package lints clean at `HEAD`. |
| `go test -race ./...` | all packages pass (local Postgres via `docker compose up -d postgres`) |
| `sqlc generate` + `buf generate` twice | output identical; auth's generated proto unchanged, so generator versions match CI's pins |
| Migrations 0025-0027 | `up`, `down 3`, `up` on a scratch database, clean each way |

## Items

### 1. ADRs

- `docs/decisions/adr-010-credits-and-billing-module.md`
- `docs/decisions/adr-011-analytics-and-telemetry.md` (decision recorded; built in 29D-29F)
- `docs/decisions/adr-012-remote-config-and-feature-flags.md`
- ADR-001 module list updated (billing's real contents; flags as a platform package; analytics planned).

### 2. Flags

- Migration `0025_feature_flags`: `ops.feature_flags` (key, enabled, ordered rules, optional JSON value, updated_at/by) and `ops.feature_flag_audit`. Seeds the five plan-29 flags; `billing.plans.visible` allowlists the eight seeded test user ids and the `meetups.test` domain.
- `internal/platform/flags`: pure `Evaluate` (user ids, email domains, min app version, percentage by `sha256(key, user)`, first match wins, optional `"result": false`), `Validate`, `CompareVersions`, a `Service` with a 30 s cache that keeps the last good copy on a failed reload and looks up an email only when a rule needs it, and a Postgres store whose `Set` writes the audit row.
- `internal/platform/clientinfo`: gateway middleware reading `X-App-Version` / `X-Platform`, client and server gRPC interceptors carrying them as metadata. Sanitised; never used for access.
- `GET /v1/app-config` (signed in or out) through `OpsService.GetAppConfig`.
- Tests: `flags_test.go` (`TestEvaluate` 18 cases, `TestCompareVersions`, `TestBucketIsStableAndSpread`, `TestValidate`, cache TTL, stale-copy-on-failure, no-table error, unknown/invalid flags off, email looked up only when needed, failed email lookup fails closed); `store_postgres_integration_test.go` (seeded flags and allowlist, `Set` + audit, operator required, invalid rules refused); `clientinfo_test.go` (header sanitising, metadata round trip); `grpcapi/appconfig_test.go`; gateway `TestAppConfigWorksSignedInAndOut`.

### 3. Schema

- `0026_billing_schema`: `wallets` (non-negative CHECK; `debt` separate), `credit_lots` (spend-order index), `holds` (unique `(user_id, idempotency_key)`), `hold_allocations`, `ledger_entries` (unique `(user_id, idempotency_key)`, trigger rejecting UPDATE and DELETE), `price_rules` (one active; the default document), `plans` (`pro`, plus operator-only `enterprise`), `subscriptions`, `plan_usage`, `welcome_grants` (unique user and unique fingerprint), `billing_outbox`, `refund_log` (unique per hold), plus `admin_audit` and `reconciliation_runs`.
- `0027_meetup_billing`: capacity CHECK 1-30; `creation_key` (unique per host) and `charge_hold_id`; `meetup.billing_outbox`.
- Down migrations for all three. 0027's down re-adds the 1-20 CHECK as `NOT VALID` so a rollback does not fail on meetups created with 21-30 places.

### 4. Ledger core (`billing/wallet`)

Grant, due decay and expiry for one user, reserve, capture (expiring-first allocation in batches of 8), release, refund to original lots (then re-applying the lots' expiry and decay), debt and its pay-off from later grants, operator removal. Every write is `Ledger.Do`: one transaction, the wallet row `FOR UPDATE` first, ledger entries with per-user idempotency keys, `credits.changed` queued when figures move.

Tests: `decay_test.go`; `billing/ledger_integration_test.go`: `TestWelcomeCreditsDecayWeekly`, `TestSpendBetweenSweepsSeesTheDecayedBalance`, `TestSpendOrderAndRefundToOriginalLots`, `TestRefundToAnExpiredLotExpiresWithIt`, `TestCaptureAfterTheHoldExpired` (both cases), `TestCaptureIsIdempotent` (5 concurrent), `TestCancelBeforeCaptureReleases`, `TestLedgerIsAppendOnly`, `TestReconciliationFindsTamperingAndRunsOncePerDay`, `TestLedgerPagination`, `TestDeletedAccountWalletIsClosed`. Every money test ends by asserting the ledger replays to the wallet.

### 5. Pricing (`billing/pricing`)

Strict parse (unknown fields, fractional credits, cheaper later bands and so on are refused), validation, pure `Price`. Tests: `TestPriceWithTheDefaultRules` (12 cases, priced from the document in the migration itself), `TestPriceOutsideTheRange`, `TestPriceIsMonotonic` (property test over the default rules and 50 random valid documents, 2,000 samples each), `TestParseRejectsBadDocuments`.

### 6. Entitlements

Free versus plan limits; plan quota holds against `plan_usage` (`used + held < meetups_included`, under the wallet lock). Test: `TestPlanQuotaAndLimits` (capacity 30 and 30-day lead refused without a plan, allowed with one; 10 creations covered, the 11th costs 10 credits; entitlements report it), `TestLimitsWhileNotEnforcedKeepTodaysBehaviour`.

### 7. Welcome credits

Granted lazily on the first wallet, quote or entitlements call at trust level 3 or more (from the JWT). `IdentityFingerprint` port; the auth adapter in `wiring.go` returns an HMAC of the verified phone, else the verified personal email. Test: `TestWelcomeGrantOncePerUserAndPerPerson` (15 concurrent first calls by one user; two accounts sharing one phone, called concurrently; level 2 gets nothing).

### 8. Sweeps

On the ops tick: `outbox: meetup billing events`, `billing: expired holds`, `billing: decay and expiry`, `outbox: billing`, `billing: reconciliation` (daily), and retention for both outboxes. Test: `TestScheduledTickRunsEveryBillingSweep` in `deploy_manifest_test.go` (parses `billing/sweeps.go` and fails if a sweep or either outbox drain is missing from `main.go`).

### 9. Meetup integration

`meetup.CreationCharger` (owned by meetup; adapter in `wiring.go`). Create order: validation and the trust gate unchanged, then idempotency check, quote, limits, expected cost, reverse geocoding, reserve, then the existing transaction, which now checks the creation key under the host's lock, stores the hold id and writes `meetup.created` to `meetup.billing_outbox`. A failed create releases the hold; a concurrent retry gets the winner's meetup. `meetup.cancelled` / `meetup.closed` (with `accepted_count`, `window_start`, `ended_at`) are written in the cancel, close and auto-close transactions; billing applies the refund policy and the 3-per-30-days cap. `apperror.ErrPaymentRequired` and `ErrUpgradeRequired` with `CodedError`, carried as a gRPC `ErrorInfo` detail and mapped to 402/409/426 with a structured body.

Tests (`cmd/monolith/billing_pipeline_test.go`, real meetup + billing + the production adapter and outbox step, `-race`): `TestConcurrentCreatesChargeExactlyTwo` (20 goroutines, 25 credits, cost 10 → 2 created, 18 refused with 402, balance 5, nothing held, ledger replays), `TestSameIdempotencyKeyConcurrentlyChargesOnce` (5 concurrent + 1 later → one meetup, one hold, one charge), `TestFailedCreateAfterReserveReleasesTheHold`, `TestCreatePricingErrors` (426 for an old build and for no header; 409 for missing and stale expected cost; 15-day and capacity-21 limits; the trust gate still refuses Level 2), `TestEnforcementOffWritesNoBillingRows`, `TestCancelRefundsThroughTheOutbox`, `TestAutoCloseWithNobodyRefundsHalf`. `apperror/coded_test.go` covers the error mapping; the existing meetup suite passes unchanged.

### 10. Endpoints

`GET /v1/billing/wallet`, `GET /v1/billing/ledger` (keyset cursor), `POST /v1/billing/quote` (strict body), `GET /v1/billing/entitlements`, each 60/min per user. The store routes stay 503 for 29B (none of the four new routes was in `unavailable.go`, so nothing there was replaced). Tests (`gateway/handlers/billing_test.go`): auth required on all four, user id taken only from the token (query `user_id` ignored), unknown quote fields refused, coded errors → 402/409/426 with their fields, create forwards `expected_cost` / `price_version` / `Idempotency-Key` and refuses a malformed key, old-shape create still works, store routes still 503, per-user rate limit independent per user.

### 11. Admin CLI

`cmd/billingadmin`: `grant`, `adjust`, `show-wallet`, `set-plan` (`pro`, `enterprise`, `none`), `flags show|set`. `--operator` and `--reason` required and checked before connecting; grants and adjustments are idempotent by key (derived from the arguments by default). Tests: `TestChangesNeedAnOperatorAndAReason`, `TestBadArguments`, `TestGrantIsIdempotentAndAudited`, `TestFlagsSetAndShow`.

### 12. Docs

`docs/api/billing.md`, runbook §12 (`docs/deploy/gcp-runbook.md`), tracker rows 29A-1 to 29A-4 in `docs/gap-tracker.md`.

## On "every behaviour gets a test that fails first"

The tests were written alongside the code, not each one strictly before it. The
coded-error test was run first and failed (it did not compile without the type).
To show the money-path tests actually catch the bugs they are about, I broke the
code on purpose one way at a time and re-ran the matching test:

| Mutation | Test | Result |
|---|---|---|
| Skip the available-balance check in `Reserve` | `TestConcurrentCreatesChargeExactlyTwo` | fails |
| Skip the creation-key lookup in the create transaction | `TestSameIdempotencyKeyConcurrentlyChargesOnce` | fails |
| Remove the release after a failed create | `TestFailedCreateAfterReserveReleasesTheHold` | fails |
| Skip the expected-cost check | `TestCreatePricingErrors` | fails |
| Spend purchased credits first (`NULLS FIRST`) | `TestSpendOrderAndRefundToOriginalLots` | fails |
| Remove the 30-day refund cap | `TestRefundPolicy` | fails |
| Never apply decay | `TestWelcomeCreditsDecayWeekly` | fails |
| Enforce the 14-day window while not enforced | `TestEnforcementOffWritesNoBillingRows` | fails |
| Narrow the welcome-grant `ON CONFLICT` to `user_id` | `TestWelcomeGrantOncePerUserAndPerPerson` | passes, correctly: the fingerprint's unique index still rejects the second grant, as an error instead of a no-op |

Writing these tests also found one real bug: a full-refund cancellation that
arrived before the creation's capture released the hold, and the late capture then
charged it anyway. Capture now skips a hold released for that reason
(`wallet.ReleaseSettled`).

## Deviations from the prompt and the plan

1. *(Superseded 2026-10-25: credits have no flag, so 14 days applies from day one.)*
   **The 14-day free advance window applies only while `credits.enforced` is on.**
   The prompt asks for entitlement limits in `Create`, and they are enforced there,
   but with enforcement off the advance limit is the 90 days the shipped app already
   offers. Enforcing 14 days on deploy would break app builds already on phones,
   against the standing backward-compatibility rule. Capacity stays 20 without a
   plan either way.
2. **The welcome fingerprint's HMAC key is the existing work-email HMAC key**, under
   its own domain prefix, rather than a new secret. Same mount, no new deploy step;
   the prefix makes the two uses incomparable.
3. **Email-domain flag rules read the account's verified personal email** (what the
   seeded `@meetups.test` accounts sign in with), looked up through auth only when a
   rule needs it.
4. **Additions beyond the plan's table list:** `ops.feature_flag_audit`,
   `billing.admin_audit`, `billing.reconciliation_runs`, `meetup.billing_outbox`; a
   `value` column on flags (for `analytics.sample_rate`); `held_delta`,
   `debt_delta`, `held_after`, `debt_after` on the ledger so holds and debt replay
   too; and retention sweeps for the two new outboxes.
5. *(Superseded 2026-10-25.)* **With enforcement off, the quote returns `cost: 0` plus `would_cost`**, so the
   UI can show real prices before billing is on.
6. **A create without `expected_cost` while enforced is 409 `price_changed`**, not a
   charge at the server's price; the client must have shown the cost. Old builds are
   stopped earlier by the 426.
7. **`Idempotency-Key` is optional**; without it every request is its own creation.
   A malformed key is 400 rather than dropped.
8. **Account deletion closes the wallet** (plan 3.6) through the user-deleted outbox;
   the welcome-grant row is kept so a re-created account cannot claim again.
9. **A partial refund of a plan-quota creation returns nothing** (half a unit is
   not a unit); a full refund returns the unit.
10. **The daily reconciliation runs per UTC day.** The 29F report runs on Colombo
    time; aligning them is 29F's call.
11. **The release-after-failed-create check is a read outside the lock**, so a
    same-key retry can still commit in the gap. The backstop is capture-after-release
    (re-spend, or debt), as the plan describes for expired holds.
12. ADR-031 (vault) was not needed for 29A; plan §3.7's summary was enough for the
    port boundaries 29B will fill.

## Not done here (by design)

29B (store verification, purchases, subscriptions, catalog, V-20), 29C (Flutter),
29D-29F (analytics and the report). Since 2026-10-25 credits have no flag, so
the backend must deploy with the 29C app release, with `MIN_CREDITS_APP_VERSION`
set to that build (runbook §12).

## Review fixes (2026-10-24)

An independent review of the 29A working tree found seven problems. Each fix
came with a test that failed before the change (failure output below), and the
gates were re-run afterwards: `go vet`, `gofmt`, `golangci-lint` (0 issues, clean
cache), `go test -race ./...` (31 packages pass, none fail), migrations 0025-0028
up / down 4 / up on a scratch database.

| # | Problem | Fix | Test (failed before → passes) |
|---|---|---|---|
| 1 | **High.** `Reserve` returned any existing hold for a key, so a key whose 10-credit create failed could carry a 48-credit meetup at the old price | A hold under the key is reused only if it is `held` or `captured` **and** kind, amount and price version match. The same request after a release supersedes the old hold's key and reserves afresh; anything else is 409 `idempotency_key_reused` (new `apperror` code, mapped to 409 through gRPC and HTTP, documented) | `cmd/monolith TestIdempotencyKeyAfterAFailedCreate` — before: `bigger body with a used key: <nil>, want idempotency_key_reused` (the bigger meetup was created on the old hold). After: 409, nothing charged; the same body with the same key later succeeds and charges once. Also `apperror TestCodedErrorRoundTripsThroughGRPC` (new 409 case) |
| 2 | **Medium.** With `credits.enforced` off, every create still wrote a wallet row and, with the fingerprint adapter wired, granted welcome credits that decayed unused. Unreadable flags with no cache failed creation | Not enforced → `Quote` is read-only, no wallet, no welcome grant (welcome waits for enforcement). `Enforced` now returns a bool: an unreadable flag is treated as not enforced, logged, and counted in the new `billing_flag_read_failures_total` | `TestEnforcementOffWritesNoBillingRows` (now with the real `identityFingerprint` adapter, asserting zero rows for the host in wallets, lots, ledger, holds, welcome grants and both outboxes) — before: one row each in wallets, credit_lots, ledger_entries, welcome_grants, billing_outbox. `TestUnreadableFlagsFailOpenToNotEnforced` — before: `billing: read credits.enforced: internal error`. `billing TestWelcomeCreditsWaitForEnforcement` |
| 3 | **Low/Medium.** The ledger could be emptied with TRUNCATE | Migration `0028_ledger_no_truncate` (with down): `BEFORE TRUNCATE ... FOR EACH STATEMENT`. Test harnesses no longer truncate the ledger; every test uses fresh user ids and scopes its ledger assertions to them | `TestLedgerIsAppendOnly` — before: `TRUNCATE of the ledger succeeded` |
| 4 | **Low.** A cancellation that landed before its capture released the hold without counting toward the 3-per-30-days cap | `CountRefundsSince` counts `released` too; the cap is checked before the release branch, and a capped early cancellation is captured and logged `skipped_cap` | `TestCancelBeforeCaptureCountsTowardTheRefundCap` — before: the 4th early cancellation left the balance at 100 (free) |
| 5 | **Low.** A full refund of a capture that had gone into debt paid that same debt from the refunded credits | On a 100% refund, the debt recorded by that hold's own capture (`capture:<hold>:debt`) is written off first, as a keyed `refund` entry | `TestFullRefundWritesOffTheCapturesOwnDebt` — before: `{Balance:0 Debt:2}`, want balance 4 and debt 0 |
| 6 | **Low.** The flag email resolver used the personal email whether verified or not | Returns it only when `PersonalEmailVerified` | `cmd/monolith TestFlagEmailResolverReturnsOnlyAVerifiedEmail` — before: `unverified email resolved to "x@meetups.test"`. Also `TestIdentityFingerprintUsesOnlyVerifiedAnchors` (passed before; pins the adapter) |
| 7 | **Tidy.** `wallet.go` was 851 lines | Split into `wallet.go` (410: transaction, entries, grants, removal), `holds.go`, `capture.go`, `refunds.go`, and `decay.go`. Declarations moved byte for byte (checked by script: all 33 present and unchanged) | Full suite before and after: 31 packages pass both times |

Item 2's fail mode is a decision: **treat unreadable flags as not enforced**. It
costs a missed charge at worst and keeps hosting up; the counter and the log line
make it visible (runbook §12, ADR-010).

## Change after review: credits have no flag (2026-10-25)

Product decision: hosts use and buy credits from day one; only subscription
plans, which launch later, are switched. So `credits.enforced` and
`billing.credit_packs.visible` are gone, and review fix 2 (no billing writes and
a "not enforced" fail mode while the flag is off) no longer applies.

- **Removed:** both flags (constants and the 0025 seed), `billing.Service.Enforced`,
  the flag dependency of the billing module, the `Enforced` fields on `Quote`,
  `Entitlements`, `ReserveRequest` and `meetup.CreationQuote`, the `unenforced`
  90-day window in the price rules (0026 seed and parser), and the
  `billing_flag_read_failures_total` metric.
- **Now always:** every create is priced and held, the welcome credits are granted
  on a hosting-level user's first billing call, and the free limits are 20 people
  and 14 days. An app build below `MIN_CREDITS_APP_VERSION` gets 426 on create.
- **Kept on the wire:** `credits_enforced` in the quote and entitlements responses,
  always `true`, so the response shape is unchanged.
- **Migrations 0025 and 0026 were edited in place**: neither has run anywhere but
  local test databases (the dev database is at schema 24). A test database that
  already ran them must be recreated.
- **Tests:** `TestEnforcementOffWritesNoBillingRows`,
  `TestUnreadableFlagsFailOpenToNotEnforced`, `TestLimitsWhileNotEnforcedKeepTodaysBehaviour`
  and `TestWelcomeCreditsWaitForEnforcement` were removed with the behaviour they
  tested. New: `billing TestFreeLimitsApplyWithoutAPlan`,
  `billing TestFirstQuoteGrantsWelcomeCredits`,
  `cmd/monolith TestNewHostPaysWithWelcomeCredits` (a new verified host creates a
  meetup on welcome credits alone: 60 → 50), and `TestSeededFlags` now asserts
  neither credit flag is seeded.
- **Gates:** `go vet`, `gofmt`, `golangci-lint` (0 issues), `go test -race ./...`
  (31 packages pass), buf regenerated, migrations 0025-0028 up / down 4 / up on a
  scratch database (only `billing.plans.visible` and the two analytics flags
  seeded).
- **Deploy consequence:** the shipped builds are 1.0.0, below the 1.1.0 default,
  so deploying before the 29C app release stops everyone hosting until they update.
