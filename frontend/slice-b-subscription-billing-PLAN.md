# Frontend plan — Slice B: mobile Premium purchase (StoreKit + Google Play Billing)

Full design in `docs/04-decisions/adr-031-subscription-billing-architecture-slice-b.md`. Frontend only. No web checkout, no Stripe, no PayHere UI this round.

## Step 1 — Dependency

Add `in_app_purchase` (confirm current stable version against pub.dev at implementation time, same discipline as this codebase's other dependencies). This single Flutter package wraps both StoreKit2 (iOS) and Google Play Billing (Android) behind one Dart API — do not add separate platform-specific purchase packages.

## Step 2 — Service-contract pattern (match this codebase's established shape)

New `SubscriptionService` interface in `lib/core/services/` (mirroring `AuthService`/`MeetupService`): `Future<SubscriptionStatus> currentStatus()`, `Future<List<ProductDetails>> availableProducts()`, `Future<PurchaseResult> purchase(String productId)`, `Future<void> restorePurchases()`. Real implementation (`HttpSubscriptionService` or similar) calls the new `billing` service's REST routes via the gateway; wire it into `app_providers.dart` the same way every other real service is wired.

## Step 3 — Purchase flow UI

- A Premium/upgrade screen (or a section of `ProfilePage`, whichever fits this app's existing navigation better — check for a natural existing entry point before adding a new one) listing available products (`in_app_purchase`'s `queryProductDetails`), a "Subscribe" action per product.
- On purchase: use `in_app_purchase`'s stream-based purchase-update listener (`InAppPurchase.instance.purchaseStream`) — **do not poll for purchase completion**, this package is stream-driven by design. On a completed purchase, send the receipt/token to the backend's `VerifyPurchase` via `SubscriptionService.purchase(...)`, and **only mark the purchase as "delivered" to the platform (`completePurchase()`) after the backend confirms verification succeeded** — completing too early risks the platform considering it delivered when the backend never actually recorded it.
- Handle every `PurchaseStatus` the stream can emit (`pending`, `purchased`, `error`, `canceled`, `restored`) — a purchase flow that only handles the happy path is a real gap, not a nice-to-have.
- A "Restore Purchases" action (required by Apple's guidelines for any app with non-consumable/subscription purchases) — calls `InAppPurchase.instance.restorePurchases()`, re-verifies each restored purchase against the backend the same way a fresh purchase is verified.

## Step 4 — Subscription status display

Read `SubscriptionService.currentStatus()` (backed by the backend's `subscriptions` row, not any client-side purchase-stream state) wherever the app needs to know the user's tier — this is the same "server decides, client only displays" principle every other feature in this app already follows. Don't derive "am I premium" from local purchase-stream state; that's a client guess, not the source of truth.

## Tests

- Fake the `InAppPurchase` platform interface (check whether `in_app_purchase_platform_interface` offers a settable fake instance, the same pattern already used for `geolocator_platform_interface`/`flutter_secure_storage_platform_interface` in this codebase's `dev_dependencies`) to test the purchase-stream handling logic without a real store.
- Test every `PurchaseStatus` branch is handled (not just `purchased`).
- Test that `completePurchase()` is only called after a successful backend verification response, not immediately on `purchased` status.
- Test `SubscriptionService.currentStatus()` is what gates any Premium-only UI, not local purchase state.

## Do not

- Do not build a web checkout UI or PayHere integration this round.
- Do not mark a purchase complete to the platform before the backend has verified it.
- Do not derive subscription/entitlement state from local purchase-stream data anywhere it matters — always read the backend's `currentStatus()`.

## Full checklist

`flutter analyze --fatal-infos`, `dart format --set-exit-if-changed`, `flutter test` — report the real total from the test runner's own summary line.
