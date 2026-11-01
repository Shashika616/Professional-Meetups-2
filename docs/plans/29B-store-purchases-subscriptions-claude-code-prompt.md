# Claude Code prompt 29B: store purchases, subscriptions, catalog

Read first: `docs/plans/29-credits-billing-analytics.md` (sections 1, 3.6 to 3.9, 5, 6), `docs/plans/29A-completion-report.md`, `docs/decisions/adr-010-credits-and-billing-module.md`, and the code to port in the sibling repo `../Professional-Meetups/backend/services/billing/` (`internal/verify`, `internal/webhookauth`, `internal/service/webhooks.go`, `internal/repository`, `db/migrations/billing/0001_billing.up.sql`, `proto/billing/v1/billing.proto`). Read the sibling code fully before porting; it was reviewed in ADR-031 and should be ported, not rewritten. Do not modify the sibling repo.

## Goal

Credit packs (consumables) and subscriptions purchased through Apple and Google, verified server-side, granted exactly once, reversible on refund, and a server-driven catalog with plans hidden by `billing.plans.visible`.

## Hard rules

Same as 29A (working tree only, test fixtures untouched, trust never sold, server-side amounts, module boundaries, tests first, `-race` on money paths). Additionally:

1. Never log or store a raw receipt, purchase token or signed transaction beyond what `store_purchases.raw` needs, and strip personal data from `raw`.
2. Production fails closed: missing Apple or Google credentials make verify return 503 with a clear log line; never fall back to trusting the client. The `fake` verifier is only selectable when not on Cloud Run.
3. A verified paid purchase is never refused because of a flag; grant it and log a warning.
4. Hard-code store endpoints; no user-supplied URLs.

## Work, in order

1. Port `verify` and `webhookauth` into `internal/modules/billing/store/{apple,google,fake}` behind `StoreVerifier`. Keep the embedded Apple Root CA and its tests. Breaker plus bounded retry plus timeouts on every outbound call.
2. Migrations: `store_purchases`, `processed_store_notifications` (plan 3.1); seed `plans` product ids and the credit pack catalog (`credits_50`, `credits_120`, `credits_300` per D6).
3. `POST /v1/billing/purchases/verify` `{platform, product_id, token}`:
   - Check the product id is in the catalog and its kind.
   - Verify with the store; check bundle id or package name, environment (sandbox accepted only for allowlisted test accounts or non-production), product id, and that the account token equals UUIDv5(namespace, caller user id).
   - Consumable: one transaction inserts `store_purchases`, creates a non-expiring purchase lot, writes the ledger entry and `credits.changed` to `billing_outbox`. Duplicate verify returns the original result. After commit, Google acknowledge and consume (retried by an outbox job until done).
   - Subscription: as ADR-031, upsert `subscriptions`, set the plan period, enqueue `subscription.activated`.
   - Response: the new wallet and subscription state.
   - Rate limit 10 per minute per user.
4. Webhooks `POST /v1/billing/webhooks/apple` (Server Notifications V2, JWS chain) and `/google` (RTDN via Pub/Sub push OIDC): verify first, then idempotent by notification id. Map renewals, grace period, expiry, revoke, refund (subscription and consumable) and Google voided purchases to state changes. Consumable refund removes the remaining credits of that lot and records debt for any already spent (plan 3.6).
5. `GET /v1/billing/subscription` and `GET /v1/billing/catalog` (plan 3.8), flag-filtered per caller; catalog has no prices.
6. Publish `subscription.activated/deactivated` through `billing_outbox`; fix V-20 (schema-qualify `meetup.subscription_cache` in the hand-written SQL) and make entitlement checks use billing (not the cache) where quota is consumed.
7. Remove the implemented routes from `unavailable.go` and update `handlers_test.go`.
8. Docs: `docs/api/billing.md`, a store setup checklist `docs/deploy/store-setup.md` (every console step from plan section 9, with the review-notes text for the hidden plans), runbook secrets list.

## Tests that must exist

- Verify the same transaction twice, and concurrently 10 times → one lot, one ledger entry.
- A transaction whose account token belongs to another user → rejected, nothing written.
- Wrong bundle id, wrong environment, unknown product, expired or revoked subscription → rejected.
- Webhook with a bad signature → 401 and nothing written; the same notification twice → one change.
- Consumable refund after partial spend → remaining removed, debt recorded, meetup creation blocked until paid off by a new grant.
- Catalog: plans hidden for a normal user, visible for an allowlisted test user, visible for everyone after the flag flips, never contains prices.
- Missing store credentials on Cloud Run → 503, never a grant.
- Fake verifier unavailable when `K_SERVICE` is set.

## Finish

Same gates as 29A. Report at `docs/plans/29B-completion-report.md`. Do not start 29C.
