# 29B completion report: store purchases, subscriptions, catalog

Working tree only. Nothing committed, pushed or deployed; no `gcloud`, no
production database. 29C was not started.

Every item below has a passing test. Real Apple and Google calls need
credentials only the owner can create; until they are set, purchases answer
503 (`docs/deploy/store-setup.md`).

## Gates

| Gate | Result |
|---|---|
| `go vet ./...` | clean |
| `gofmt -l .` | clean |
| `golangci-lint run ./...` | 0 issues (clean cache) |
| `go test -race ./...` | 35 packages pass, none fail (local Docker Postgres, `monolith_db_test`) |
| sqlc and buf, second run | no diff (`sqlc diff` clean; buf output hash unchanged) |
| Migrations | 0029 up, down 5, up on a scratch database; the catalog seeds as D5/D6 |

## Items

| # | Item | Where | Tests |
|---|---|---|---|
| 1 | Port `verify` and `webhookauth` behind `StoreVerifier`, with the embedded Apple Root CA and its tests; breaker, bounded retry and timeouts on every outbound call | `internal/modules/billing/store` (`store.go`, `resilient.go`), `store/apple`, `store/google`, `store/fake` | The sibling's tests, ported: `TestVerifyJWS*` (valid, untrusted chain, tampered, no x5c), `TestOIDC*`, `TestParseJWKS`. Added: `TestVerifyJWSRejectsAChainWithoutAppleMarkers`, `TestRootIsAppleRootCAG3` (SHA-256 pin), `TestVerifyFetchesApplesCopyFromTheRightHost`, `TestVerifyUsesApplesCopy`, `TestVerifyClassifiesFailures` (both stores), `TestVerifyOneTimeProduct`, `TestVerifySubscriptionDropsPersonalData`, `TestFinishConsumesOrAcknowledges`, `TestResilientRetriesOnlyTransientFailures`, `TestResilientBreaker`, `TestUnconfiguredFailsClosed` |
| 2 | Migrations: `store_purchases`, `processed_store_notifications`; plan product ids and the credit pack catalog (D6) | `migrations/0029_store_purchases` | Migrations up/down/up; `TestCatalogShowsPlansOnlyWhereTheFlagSays` reads the seed |
| 3 | `POST /v1/billing/purchases/verify`: catalog and kind; store verification; bundle or package, environment, product, account token; consumable grant in one transaction with `credits.changed`; duplicate returns the original; Google consume or acknowledge after commit, retried by an outbox job; subscriptions upserted with `subscription.activated`; 10 a minute per user | `billing/purchases.go`, `billing/subscriptions.go`, gateway `billing.go` | `TestVerifyGrantsAPackExactlyOnce`, `TestAnotherAccountsPurchaseIsRejected`, `TestVerifyRejectsWhatTheStoreSaysOtherwise`, `TestSandboxPurchasesOnlyForTheAllowlist`, `TestGoogleFinishIsRetriedThroughTheOutbox`, `TestVerifiedSubscriptionActivatesThePlan`, `TestVerifyPurchaseForwardsOnlyWhatTheStoreGave`, `TestVerifyPurchaseIsLimitedTo10AMinute` |
| 4 | Webhooks: Apple V2 (JWS chain) and Google RTDN (Pub/Sub OIDC), verified first, idempotent by notification id; renewals, grace, expiry, revoke, refunds of both kinds, Google voided; a pack refund removes what is left and records debt | `billing/notifications.go`, `wallet.RevokeLot` | `TestAppleWebhookVerifiesFirstAndAppliesOnce`, `TestGoogleWebhookVerifiesFirstAndAppliesOnce`, `TestPackRefundAfterPartialSpendRecordsDebt`, `TestGoogleVoidedPackIsTakenBack`, `TestParseNotificationVerifiesEverythingInside`, `TestStoreWebhooksForwardTheRequestUntouched`, `TestStoreWebhookVerificationFailureIs401` |
| 5 | `GET /v1/billing/subscription` and `GET /v1/billing/catalog`, filtered per caller, no prices | `billing/catalog.go`, `billing/subscriptions.go` | `TestCatalogShowsPlansOnlyWhereTheFlagSays`, `TestCatalogWorksSignedInAndOutAndHasNoPrices`, `TestAllowlistedIgnoresTheDefault` |
| 6 | `subscription.activated`/`deactivated` through `billing_outbox`; V-20; entitlement checks use billing, not the cache | `cmd/monolith/store_wiring.go`, `meetup/repository/subscription_cache_postgres.go` | `TestSubscriptionCacheUpsertAndRead` (V-20), `TestSubscriptionEventsReachTheMeetupCache` |
| 7 | Remove the implemented routes from `unavailable.go`; update `handlers_test.go` | `unavailable.go` deleted (nothing else used it) | `TestStoreRouteAuth` replaces the two "still 503" tests |
| 8 | Docs: `docs/api/billing.md`, `docs/deploy/store-setup.md`, runbook secrets | runbook §1 secrets table and §13 | none (docs) |

## The required tests

| Required | Test | Shown failing when broken |
|---|---|---|
| Same transaction twice and 10 at once: one lot, one ledger entry | `TestVerifyGrantsAPackExactlyOnce` | Granting again on a repeat fails it |
| Another user's account token: rejected, nothing written | `TestAnotherAccountsPurchaseIsRejected` | Removing the account token check fails it |
| Wrong bundle id, wrong environment, unknown product, expired or revoked subscription: rejected | `TestVerifyRejectsWhatTheStoreSaysOtherwise` | Removing the app check fails it; removing the environment check fails it |
| Webhook with a bad signature: 401, nothing written; the same notification twice: one change | `TestAppleWebhookVerifiesFirstAndAppliesOnce`, `TestGoogleWebhookVerifiesFirstAndAppliesOnce` | Ignoring the idempotency record fails it. The first version survived this mutation (re-expiring an expired plan is invisible), so the test now redelivers an old EXPIRED after a renewal |
| Pack refund after partial spend: remaining removed, debt recorded, creation blocked until a new grant pays it | `TestPackRefundAfterPartialSpendRecordsDebt` | Skipping the debt fails it |
| Catalog: hidden for a normal user, visible for an allowlisted test user, visible for all after the flag flips, never a price | `TestCatalogShowsPlansOnlyWhereTheFlagSays` | Ignoring the flag fails it |
| Missing store credentials on Cloud Run: 503, never a grant | `TestUnconfiguredStoreFailsClosed`, `TestStoresFailClosedWithoutCredentialsOnCloudRun` | Mapping "not configured" to anything but 503 fails it |
| Fake verifier unavailable when `K_SERVICE` is set | `TestFakeStoreIsRefusedOnCloudRun` | none (a startup refusal; passes and is asserted directly) |

Further mutations, each caught: sandbox checked with `Enabled` instead of the
allowlist (`TestSandboxPurchasesOnlyForTheAllowlist`), and dropping Apple's
marker-extension check (`TestVerifyJWSRejectsAChainWithoutAppleMarkers`).

## Deviations and decisions

1. **Apple is verified twice, and so needs credentials.** The sibling verified
   only the app's signed transaction, locally, with no Apple call. Plan 3.7
   and hard rule 2 ask for the App Store Server API and for 503 without
   credentials. Both are done: the app's copy is verified first (a forged token
   never reaches Apple), then Apple's own copy is fetched by transaction id.
   That second fetch is what catches a refund the app's copy predates.
2. **Apple certificate markers.** On top of the port, the leaf and the
   intermediate must carry Apple's App Store marker extensions, as Apple's own
   library requires. Otherwise any certificate Apple issued under G3, for any
   purpose, would chain.
3. **Google uses the v3 `purchases.subscriptions` API, as the sibling did**,
   plus `purchases.products` for packs. The v3 subscription resource can carry
   the buyer's name and email; those fields are never decoded, so they cannot
   reach `raw` (a test checks this). The service account file's `token_uri` is
   ignored and the token endpoint is hard-coded (rule 4).
4. **The Google purchase token is stored, briefly.** Consume and acknowledge
   need it, and the outbox job that retries them needs it after the request
   has gone. It is kept in `store_purchases.pending_finish_token` only until the
   call succeeds, then set to NULL. Everywhere else only its SHA-256 is stored.
   This is the one exception to "never store a token beyond `raw`". The
   alternative was to keep it in `raw` or in an outbox row, both of which last
   longer.
5. **The verifier takes the product kind.** `StoreVerifier.Verify` takes a
   request carrying the kind, because Google answers one-time products and
   subscriptions at different endpoints. The kind always comes from the
   catalog, never from the app.
6. **The sandbox allowlist is `billing.plans.visible`'s rule list, not the
   flag.** A new flags method, `Allowlisted`, answers "does a rule match"
   regardless of the default. So turning plans on for everyone does not let
   everyone pay with sandbox money. No new allowlist was created (29A hard
   rule 2). Off Cloud Run, sandbox purchases are accepted from anyone.
7. **Credit packs have no flag.** As decided on 2026-10-25, packs are always in
   the catalog. Only plans are filtered.
8. **The catalog is a table, `billing.store_products`**, which replaces
   `billing.plans.product_ids` (dropped in 0029; the down migration restores
   it). Plans gain `title` and `perks`. A pack's `credits` in the catalog is
   the total it grants, and `bonus` is the part shown as a bonus.
9. **Plan quota resets monthly** inside any billing period
   (`quotaWindowStart`), so `premium_yearly` gives 10 meetups a month, not 10 a
   year.
10. **Grace periods.** A new `grace_period_end` column holds Apple's grace end
    from the signed renewal info. Google moves the expiry itself. A
    subscription in grace stays entitled until the grace ends.
11. **One store subscription belongs to one account**, enforced by a unique
    index on `(platform, original_transaction_id)` and checked first. An
    operator's plan (`billingadmin set-plan`) now clears any store link, so a
    later store notification cannot overwrite it.
12. **A notification for a purchase this server never verified is recorded and
    acknowledged.** The store would otherwise retry it for days, and the app's
    verify call applies the same state. Google subscription types that extend
    access re-read the subscription from Google, because RTDN carries no
    state. If Google cannot be reached, the notification is not recorded and
    Pub/Sub redelivers it.
13. **Webhooks need no new rate limiter.** The blanket per-IP limit applies, the
    body is capped at 64 KB, and nothing is written before verification.
14. **The subscription events moved off the bus.** The two bus handlers that
    fed `subscription_cache` (nothing ever published to them) are replaced by
    an outbox consumer. Quota and plan limits were already read from billing,
    not the cache; the cache is now documented as display only.
15. **`unavailable.go` was deleted** rather than emptied: nothing else used it.
16. **An unusable store key is logged and treated as missing** (503) rather
    than stopping the monolith, so hosting keeps working while the key is
    fixed.

## For the owner

- Everything in `docs/deploy/store-setup.md`: products, the App Store Server
  API key, notification URLs, the Play service account, the RTDN topic and push
  subscription, testers, review notes, and legal links.
- New secrets: `apple-app-store-private-key` and `google-play-service-account`.
  New plain env values are listed in runbook §1 and §13.
- The app (29C) must send the account token on every purchase. The catalog
  returns it, and the namespace is in `docs/api/billing.md`.
- The deploy order from 29A still applies: ship the backend with the 29C app
  release.

## Review: error handling, sanitization, rollback, fault tolerance, idempotency (2026-10-25)

A follow-up pass over the 29B code found three defects. Each was fixed with a
test that failed first, and the gates were re-run: 35 packages pass under
`-race`, lint reports 0 issues, and vet and gofmt are clean.

| # | Defect | Fix | Test (failed before) |
|---|---|---|---|
| R1 | **Sanitization.** On a network failure Go's HTTP error includes the request URL, and Google's URL path carries the purchase token, so the token reached the logs | Transport errors are stripped of the URL (`withoutURL`) for Google, and for Apple to match | `TestNetworkErrorsDoNotLeakTheToken`. Before: `... Get "https://androidpublisher.../tokens/secret-purchase-token": connection reset` |
| R2 | **Fault tolerance.** Stores deliver out of order. An EXPIRED (or ON_HOLD, REFUND of an old period) arriving after a renewal ended the renewed subscription | Apple: a change that ends access carries the period it is about, and is recorded `stale` when a later period is stored. Google: before applying EXPIRED, ON_HOLD or PAUSED the subscription is re-read, and is `stale` if Google says it still runs | `TestAppleWebhookVerifiesFirstAndAppliesOnce` (late EXPIRED), `TestGoogleStaleNotificationIsIgnored`. Before: `a late EXPIRED for an earlier period ended the renewed subscription` |
| R3 | **Idempotency.** "Already consumed" was detected from the wording of Google's error, so other wording made a finished purchase retry until it was dead-lettered | When Google refuses a consume or acknowledge, the purchase is read back and its own `consumptionState` or `acknowledgementState` decides | `TestFinishTreatsAnAlreadyFinishedPurchaseAsDone`. Before: `store: purchase rejected: google has no such purchase (status 400)` |

Scanners: `govulncheck` finds no vulnerable code reachable. Its one note,
GO-2026-5932 (`golang.org/x/crypto/openpgp`, no fix published), is in a
required module, and the code never imports that package. `gosec` reports
int-to-int32 conversions of bounded values (trust level, page size, batch
sizes), plus G101 false positives on the token URL constant and query names.
None is exploitable.
