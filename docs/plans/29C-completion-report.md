# 29C completion report: Flutter credits, buy credits, server-driven Premium

This is the working tree only: nothing is committed or built for a store, and
there are no backend changes. 29D has not started. Every item below has a
passing test.

## Gates

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | No issues |
| `dart format --set-exit-if-changed lib test` | Clean |
| `flutter test` | 842 tests pass, none fail (the 5 golden tests compare on macOS and are skipped on Linux CI) |

## Items

| # | Item | Where | Tests |
|---|---|---|---|
| 1 | `AppConfigService` and `appConfigProvider` (`GET /v1/app-config`), refreshed on resume. `X-App-Version` and `X-Platform` go on every request, set in one place | `core/services/app_config_service.dart`, `core/services/client_info_http_client.dart` (wraps the auth, meetup, subscription, credit and app-config clients), `core/config/app_version.dart`, `app_shell.dart` (resume) | `app_version_test.dart` (headers; the version constant matches pubspec), `http_credit_service_test.dart` "app config" group |
| 2 | `CreditService`: wallet, ledger, quote, entitlements, catalog and consumable verify, with typed `CreditException`s and a fake in `test/support/` | `core/services/credit_service.dart`, `http_credit_service.dart`, `core/models/credits.dart`, `test/support/fake_credit_service.dart` | `http_credit_service_test.dart` (parsing, safe 503 defaults, a quote body with no money in it, cursor paging, error and offline mapping, failing fast without a session) |
| 3 | Meetup service: 402 `insufficient_credits` and `credits_debt`, 409 `price_changed` and `idempotency_key_reused`, and 426 `update_required` become typed exceptions. Creates send `Idempotency-Key`, `expected_cost` and `price_version` | `core/services/meetup_service.dart` (`CreationCharge`, five exception types), `http_meetup_service.dart` | `http_meetup_service_test.dart` "creating with credits" group |
| 4 | Schedule flow: the date picker and the capacity stepper take their limits from entitlements (14 days and 20 people if that call fails). The review step shows a Cost row, or "Included in your plan", with the balance under it. Not enough credits turns the button into Buy credits and re-quotes on return. `price_changed` shows the new cost. `update_required` shows the server's message | `features/meetups/schedule_flow.dart` | `schedule_flow_test.dart` "credits" group: cost row, plan-covered row, insufficient → buy → re-quote → success, `price_changed`, `update_required`, retry reuses the key, stepper limit, date picker limits |
| 5 | Profile: a Credits row with the balance, opening a Credits page that shows the balance, what is held, what is owed, expiring welcome credits, a Buy credits button, and history (keyset pagination, plain-language reasons) | `features/credits/credits_page.dart`, `profile_page.dart` | `credits_page_test.dart` "Credits page" group (loading, balance, expiring soon, debt, pagination, empty, error with retry, offline), `profile_page_test.dart` "credits and premium rows" |
| 6 | Buy credits page: packs from the catalog, prices from `queryProductDetails`, a product the store lacks skipped, purchase through the extended `PurchaseFlowController`, success shows the new balance | `features/credits/buy_credits_page.dart` | `credits_page_test.dart` "Buy credits page" group |
| 7 | Premium page built from the catalog: plans, titles, perks, featured, legal links. Weekly is gone because the catalog no longer lists it. The Profile row is hidden while plans are hidden, unless the account holds a subscription | `features/premium/premium_page.dart` (the `PremiumTier` enum and `premiumPerks` are removed), `profile_page.dart` | `premium_page_test.dart`, `profile_page_test.dart` |
| 8 | Restore purchases still works for subscriptions. The Credits page has no restore button | `premium_page.dart`, `credits_page.dart` | `premium_page_test.dart` (restore shown), `credits_page_test.dart` (no restore) |

## The required tests

| Required | Test |
|---|---|
| Premium: no plans when hidden | `with plans hidden there are no plans, no buy button, and the store is not asked`; `plans listed under plans_visible false are still not shown` |
| Premium: plans appear when the same app receives `plans_visible: true` (no rebuild) | `the same running page shows the plans once the server turns them on` |
| Premium: products the store does not return are skipped | `a product the store does not return is skipped` |
| Premium: never shows a server price | `prices are the store's, never the server's` (the test catalog carries a stray `price`, and it never shows) |
| Schedule: cost row, plan-covered row | `the review step shows the server's cost and the balance, and creating carries it`; `a plan-covered meetup says so instead of a cost` |
| Schedule: insufficient → buy → re-quote → success | `not enough credits: BUY CREDITS, then a new quote, then it schedules` |
| Schedule: `price_changed`, `update_required` | `price_changed shows the new cost and asks again, as a new submission`; `update_required shows the server's message` |
| Schedule: a retry reuses the same idempotency key | `a retry after a dropped connection reuses the same idempotency key` |
| Credits page: balance, expiring soon, history pagination, empty history, error and offline | The six tests in the "Credits page" group |
| Purchase controller: consumable completed only after server confirmation; a server failure leaves it pending; `applicationUserName` set | `a consumable is completed only after the server confirms the grant`; `a server failure leaves the consumable pending for the store to redeliver`; `a credit pack is bought as a consumable, carrying the account token` |
| Limits from entitlements on the date picker and the stepper | `the date picker reaches as far as the entitlement, 14 days by default`; `a plan raises the stepper to its own limit` |

For the key tests, I broke the code they guard and confirmed each one fails:

- no key reuse on retry;
- completing the purchase before the server confirms;
- dropping the account token;
- dropping the safe default for a 503;
- showing plans while the catalog says hidden;
- a hard-coded 90-day picker.

One mutation was not caught: removing the key reset on `price_changed`. That mutant is equivalent. The re-quote that follows already resets the key whenever the price differs.

## Screens (golden tests, dark and light)

`test/goldens/billing_goldens_test.dart` renders each screen in both themes, with Arial loaded so the text is readable. Copies are in `docs/plans/29C-screens/`:

- `credits_page`
- `credits_page_offline`
- `buy_credits`
- `premium_plans`
- `premium_hidden`

Each has a `-dark.png` and a `-light.png`. The schedule flow's review step is covered by widget tests rather than a golden, because reaching it needs the map step.

## Decisions and findings

1. **App version is now 1.1.0+7.** This is the first build with the credits screens. The server refuses to create a meetup for any older build (`MIN_CREDITS_APP_VERSION` = 1.1.0). The version is a constant in `app_version.dart`, not `package_info_plus` (that package is held back by the win32 constraint noted in pubspec). A test fails if the constant and pubspec disagree.
2. **The account token is computed on the device**, as UUIDv5 of the user id under the server's namespace. Test vectors from Python's `uuid5` (RFC 4122, the same as Go's `uuid.NewSHA1`) pin it to the server's value. The catalog's `app_account_token` is not needed. The token comes from the session at build time, not from `initState`: a test caught the page reading it before the session had resolved, which would have refused the purchase.
3. **No backend bugs found.** The old client sent `receipt_or_token` and read `auto_renew_status`. 29B's API takes `token` and returns `auto_renew` and `entitled`. The client now uses the new names and still reads the old ones. Builds already on phones never sent an account token, so they could not buy from the 29B backend anyway.
4. **The history hides lines that change nothing.** A creation writes a hold and a capture, and a release undoes a hold. Lines with a zero balance change are not shown, and one load reads up to three pages to find a line worth showing. Filtering on the server (`delta != 0`) would be simpler and could be a 29F tidy-up.
5. **On Android a completion error after the grant is not a failure.** The server consumes the pack with Google, so the plugin's own completion can report an error once the purchase is already consumed. The grant stands, and the test `a completion error after the grant is not reported as a failure` covers it.
6. **`update_required` is the error snack carrying the server's sentence.** The design system has no single-button dialog, and the prompt asks only for the message.
7. **A `credits` icon was added** to `AppIcons` in the set's own stroke style. Nothing in the set fitted.
8. **`HttpSubscriptionService` now goes through `DeadlineHttpClient`.** It had no deadline before. Its 503 on verify is now an error, so a purchase stays pending and is retried rather than failing silently.
9. **Wallet and catalog reads return safe defaults on a 503** (an empty wallet, no plans), so the providers never retry in a loop. A quote or a grant has no safe default, so those throw.

## For the owner

- The deploy order from 29A and 29B still applies: the backend and this build (1.1.0+7) ship together.
- On real devices the Buy credits and Premium pages show products only once the store setup (`docs/deploy/store-setup.md`) is done. Until then they show the empty states.

## Emulator test (2026-10-25)

Run on the Pixel 8 emulator against the local Docker backend, rebuilt from the
working tree at schema 29 and signed in as `l3.a@meetups.test`.

| Checked | Result |
|---|---|
| Profile shows the Credits row with the balance, and the Premium row (the account is on the plans allowlist) | Works, after the fix below |
| Credits page: 60 welcome credits, "6 credits expire on 1 Nov", history "Welcome credits +60" | Works |
| Buy credits: the balance and the empty state (the emulator has no Play products) | Works |
| Premium: catalog perks shown; no plans offered because the store has no products | Works (legal links are absent because they are not set locally) |
| The date picker stops at 8 Nov (14 days ahead, from entitlements) | Works |
| Review step: "Cost 14 credits, Your balance: 60 credits" for 6 people under 48 hours | Works, and matches the price rules |
| Confirm creates the meetup and the server captures 14 once; the meetup carries its idempotency key and charge | Works (ledger: grant 60, hold 14, capture −14, balance 46) |
| The Credits page then shows 46 and "Meetup created −14" | Works |

**Bug found and fixed:** the wallet, app-config, entitlements and subscription
providers did not depend on who was signed in. After signing out and back in
they kept the previous session's results (here a failed balance, and plans
hidden). A second account on the same phone would have seen the first
account's balance. Each provider now re-reads when the signed-in user changes.
The test `account_scoped_providers_test.dart` failed before the fix (`Expected:
<10> Actual: <60>`). After it, 843 tests pass and analyze reports no issues.

**Noticed, not in scope:** with a session whose refresh token the server does
not know (one carried over from another database), the app retried
`/v1/auth/refresh` about ten times in twenty seconds, until the gateway
answered 429. It did not sign out. This predates plan 29.
