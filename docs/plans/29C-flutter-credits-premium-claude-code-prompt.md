# Claude Code prompt 29C: Flutter credits, buy credits, server-driven Premium page

Read first: `docs/plans/29-credits-billing-analytics.md` (sections 2, 3.3 to 3.8, 6), `docs/api/billing.md`, `docs/plans/29A-completion-report.md`, `docs/plans/29B-completion-report.md`, and in `frontend/`: `lib/features/premium/{premium_page.dart,purchase_flow_controller.dart}`, `lib/core/services/{subscription_service.dart,http_subscription_service.dart,http_meetup_service.dart,meetup_service.dart,deadline_http_client.dart}`, `lib/core/providers/app_providers.dart`, `lib/features/meetups/schedule_flow.dart`, `lib/features/profile/profile_page.dart`, `lib/main.dart`, `test/premium_page_test.dart`, `test/schedule_flow_test.dart`, `test/purchase_flow_controller_test.dart`, `test/support/`.

## Goal

The app shows a credit balance, prices a meetup before it is created, handles not having enough credits, sells credit packs, and renders the Premium page from the server catalog so plans appear when `billing.plans.visible` turns on, with no app update.

## Hard rules

1. No backend changes except bugs found in 29A/29B APIs (record them in the report).
2. Use the existing design system (`AppPalette`, `FlatCard`, `PrimaryButton`, sentence case, existing empty and error states). New screens only where listed below.
3. The app never computes a price or a balance; it shows what the server returns. Prices of store products always come from the store.
4. A store transaction is completed only after the server confirms the grant (keep the existing order in `PurchaseFlowController`). Consumables use `buyConsumable(autoConsume: false)`. Pass `applicationUserName` = UUIDv5 of the user id (same namespace as the server).
5. Every new HTTP service wraps `DeadlineHttpClient`, maps 503 to a safe default (as `HttpSubscriptionService` does) so the retry policy does not loop, and maps errors to typed exceptions.
6. Tests for every state: loading, empty, error, offline, success.

## Work, in order

1. `AppConfigService` and `appConfigProvider` (`GET /v1/app-config`), refreshed on app resume; every request sends `X-App-Version` and `X-Platform` (one place, shared by all HTTP services).
2. `CreditService` (`wallet`, `ledger`, `quote`, `entitlements`, `catalog`, `verifyPurchase` for consumables) with `HttpCreditService`, typed `CreditException`s, fakes in `test/support/`.
3. Meetup service: map 402 `insufficient_credits` (`{cost, available, shortfall}`), 409 `price_changed` (new quote) and 426 `update_required` to new `MeetupException` subtypes; send `Idempotency-Key` (one UUID per review-step submission, reused on retry) and `expected_cost`/`price_version`.
4. Schedule flow:
   - The timing step's date picker and the capacity stepper read `max_advance_days` and `max_capacity` from entitlements (fall back to 14 and 20 on error).
   - The review step adds a "Cost" row from the quote (or "Included in your plan"), and the balance under it. Credits have no flag: the cost row always shows.
   - Not enough credits: the confirm button becomes "Buy credits" and opens the buy-credits page; when it returns, re-quote. `price_changed` shows the new cost and asks to confirm again. `update_required` shows the server message.
5. Profile: a "Credits" row in Preferences showing the balance, opening a Credits page: balance, credits expiring soon (welcome credits with their next decay date), a "Buy credits" button (always shown; credits have no flag), and history (keyset-paginated ledger with plain-language reasons: "Welcome credits", "Meetup created", "Refund", "Expired", "Purchased").
6. Buy credits page: packs from the catalog, store prices from `queryProductDetails`, skipped when the store lacks a product, purchase through the extended `PurchaseFlowController` (consumable path), success shows the new balance.
7. Premium page: render plans from the catalog (`plans_visible`, titles, perks, featured, legal links) instead of the hard-coded `PremiumTier` and `premiumPerks`; weekly removed by the catalog, not by code. When plans are hidden, the Premium row in Profile is hidden too (or shows only an active subscription for users who have one).
8. Restore purchases still works for subscriptions. Consumables cannot be restored, so the credits page has no restore button.

## Tests that must exist

- Premium page shows no plans when hidden, shows plans when the same app receives `plans_visible: true` (no rebuild), skips products the store does not return, never shows a server price.
- Schedule flow: cost row, plan-covered row, insufficient credits → buy → re-quote → success, `price_changed`, `update_required`, retry reuses the same idempotency key.
- Credits page: balance, expiring soon, history pagination, empty history, error and offline.
- Purchase controller: consumable completed only after server confirmation; server failure leaves it pending; `applicationUserName` set.
- Limits from entitlements applied to the date picker and stepper.

## Finish

`flutter analyze --fatal-infos`, `dart format --set-exit-if-changed`, `flutter test`. Report at `docs/plans/29C-completion-report.md`, including screenshots or golden tests of the new states in dark and light. Do not start 29D.
