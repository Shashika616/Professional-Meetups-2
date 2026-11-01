# Claude Code prompt 29A: billing foundations (credits ledger, pricing, meetup charging)

Read first: `docs/plans/29-credits-billing-analytics.md` (the whole plan; sections 1, 2, 3.1 to 3.6, 5, 7 apply here), `TESTING-NOTES.md`, `docs/decisions/adr-001-modular-monolith-architecture.md`, `docs/decisions/adr-005-*.md`, `backend/sqlc.yaml`, `backend/cmd/monolith/{main.go,wiring.go,subscriptions.go,schema_check.go}`, `backend/internal/modules/meetup/{service.go,trustgate.go,schedule_conflict.go}`, `backend/internal/modules/meetup/repository/{repository.go,meetups_postgres.go}`, `backend/internal/platform/{outbox,apperror,ratelimit}`, `backend/internal/gateway/handlers/{handlers.go,meetups.go,cron.go}`, `backend/internal/grpcapi/ops.go`, and the vault ADR-031 if you can reach it (otherwise plan section 3.7 summarises it).

## Goal

Build the `billing` module's credit core and wire meetup creation to it, behind the `credits.enforced` flag (default off). No store purchases yet (29B), no Flutter (29C).

## Hard rules

1. Working tree only: no commit, push, deploy, `gcloud`, or production database. Migrations start at `0025`; test them on the local test database.
2. Do not touch test users, seeded test emails or the scoped OTP bypass. Add the `.test` email domain and the seeded test user ids to the `billing.plans.visible` allowlist seed only.
3. Premium never sells trust: hosting still requires Level 3 and every existing meetup rule stays.
4. The client never supplies an amount, price, balance or entitlement. Integer credits only. Server clock only.
5. Module boundaries per plan section 1: schema `billing`, own sqlc entry, own `config/`, proto `backend/proto/billing/v1`, gRPC server in `internal/grpcapi/billing.go`, gateway client methods in `monolithclient`. Meetup talks to billing only through the `CreationCharger` port it defines; the adapter lives in `cmd/monolith/wiring.go`. No cross-schema SQL or foreign keys.
6. Every behaviour gets a test that fails first. Money paths get integration tests against Postgres with real concurrent goroutines and `-race`.
7. Decisions D1 to D11 use the plan defaults unless `docs/plans/29-decisions.md` exists.

## Work, in order

1. **ADRs.** Write `docs/decisions/adr-010-credits-and-billing-module.md`, `adr-011-analytics-and-telemetry.md`, `adr-012-remote-config-and-feature-flags.md` from the plan (context, decision, alternatives considered, consequences). Update ADR-001's module list.
2. **Flags.** `internal/platform/flags`: table (migration), pure evaluator (allowlist user ids, email domains, min app version, percentage rollout), 30-second cache, table tests. `GET /v1/app-config` through the `ops` service. Gateway middleware that reads `X-App-Version` and `X-Platform` into context.
3. **Schema.** Migrations for every table in plan 3.1 that 29A needs (`wallets`, `credit_lots`, `ledger_entries` with the no-update/no-delete trigger, `holds`, `hold_allocations`, `price_rules` with the default document, `plans` seeded with `pro`, `subscriptions`, `plan_usage`, `welcome_grants`, `billing_outbox`, `refund_log`). Capacity `CHECK` to 1..30 on `meetup.meetups`; add `creation_key` (unique per host) and `charge_hold_id`. Write the down migrations.
4. **Ledger core** (`internal/modules/billing/wallet`): grant, apply due decay and expiry for one user, reserve, capture (expiring-first allocation, plan 3.2), release, refund to original lots, debt. Wallet row locked `FOR UPDATE` in every write. Every write is one transaction with a ledger entry and an idempotency key.
5. **Pricing** (`billing/pricing`): rule document parsing and validation, pure `Price` function, table tests plus a property test (monotonic in capacity and lead time).
6. **Entitlements**: free versus plan limits (plan 3.4), plan quota holds against `plan_usage`.
7. **Welcome credits**: granted lazily on the first wallet, quote or entitlement call by a user whose trust level (from the JWT, passed by the gateway) is 3 or more; an `IdentityFingerprint` port implemented by an auth adapter returns the HMAC of the verified phone or personal email; unique constraints make the grant once per user and once per fingerprint.
8. **Sweeps** added to the ops sweep list and `deploy_manifest_test.go`: hold expiry, decay and expiry materialisation, `billing_outbox` drain, daily reconciliation (plan 3.2).
9. **Meetup integration** (plan 3.5): the `CreationCharger` port, `price_changed` 409, `insufficient_credits` 402 (`apperror.ErrPaymentRequired` through gRPC and HTTP mapping with a structured body), `Idempotency-Key` handling, meetup outbox event `meetup.created` with the hold id written in the create transaction, capture by the outbox consumer, release on failure. `meetup.cancelled` and `meetup.closed` events (with `accepted_count`, `window_start`, `cancelled_at`) written in the cancel, close and auto-close transactions; billing applies the refund policy (plan 3.6) with the refund cap. Advance-scheduling and capacity limits from entitlements enforced in `Create`. When `credits.enforced` is off, nothing is reserved or charged. When it is on and `X-App-Version` is older than `MIN_CREDITS_APP_VERSION`, return 426.
10. **Endpoints**: `GET /v1/billing/wallet`, `GET /v1/billing/ledger` (keyset cursor), `POST /v1/billing/quote`, `GET /v1/billing/entitlements`, with the rate limits in plan 3.9. Replace only the routes you implement in `unavailable.go`; leave the store routes at 503 for 29B.
11. **Admin CLI** `cmd/billingadmin`: `grant`, `adjust`, `show-wallet`, `set-plan` (enterprise or manual pro), `flags set|show`. Requires `--operator` and `--reason`; writes to the ledger or an audit table. No HTTP surface.
12. **Docs**: `docs/api/billing.md` (routes, request and response bodies, error codes), runbook section for the new sweeps and flags, tracker rows.

## Tests that must exist

- Concurrency: 20 goroutines creating meetups for one user with 25 credits and cost 10 → exactly 2 succeed, balance 5, no negative balance, ledger replays to the wallet.
- Same `Idempotency-Key` sent 5 times concurrently → one meetup, one charge.
- Create transaction fails after reserve → hold released, balance unchanged.
- Capture after hold expiry with and without enough balance (the second records debt).
- Decay: a 60-credit welcome lot reaches 54, 48, ... 0 at weekly boundaries; spends between sweeps see the decayed balance; rerunning the sweep changes nothing.
- Spend order: welcome credits spent before purchased ones; refunds return to the original lot and expire with it.
- Refund policy and the 3-per-30-days cap.
- Plan quota: 10 included creations, the 11th costs credits; capacity 30 and 30-day lead allowed only with a plan.
- Welcome grant once per user and once per fingerprint under concurrent first calls.
- Every billing route rejects another user's ids and unauthenticated calls; request bodies with unknown fields are rejected.
- `credits.enforced` off: no billing rows written by meetup creation.

## Finish

`go vet ./...`, `gofmt`, `go test -race ./...`, sqlc and buf regenerated and unchanged on a second run. Write `docs/plans/29A-completion-report.md` (or `29A-progress-report.md` if anything is unfinished) listing every item, its tests, and deviations. Do not start 29B.
