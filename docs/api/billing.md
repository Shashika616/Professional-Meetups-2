# Billing API (plans 29A and 29B)

The credits routes, the app-config route, what creating a meetup now carries,
and (29B) store purchases, the subscription, the catalog and the store
webhooks. Every route here is authenticated with the access token unless it says
otherwise, and every one reads the caller's own data only: the user id always
comes from the token and no route accepts one in its path, query or body.

Every request should carry two headers (all routes, not just these):

| Header | Example | Notes |
|---|---|---|
| `X-App-Version` | `1.1.0` or `1.1.0+7` | Digits and dots, optional `+build`. Anything else is ignored. Missing is treated as the oldest build. |
| `X-Platform` | `ios`, `android`, `web` | Anything else is ignored. |

Error bodies keep the existing shape, `{"error": "<a sentence to show the user>"}`.
Billing errors add a machine-readable `code` and the numbers the app needs:

| HTTP | `code` | Extra fields | When |
|---|---|---|---|
| 402 | `insufficient_credits` | `cost`, `available`, `shortfall` | Not enough credits to create this meetup |
| 402 | `credits_debt` | `debt` | An earlier charge is unpaid; creation is blocked until credits are added |
| 409 | `price_changed` | `cost`, `price_version` | The cost the app showed is not the current one (or it showed none). Re-quote, show the new cost, retry |
| 409 | `idempotency_key_reused` | none | The `Idempotency-Key` was already used for a different create (different capacity, start or price), or for one that can no longer be reused. Send a new key |
| 426 | `update_required` | none | This app build predates the credits UI (older than `MIN_CREDITS_APP_VERSION`); only creating a meetup is refused |

Purchase verification adds plain statuses (no `code`): 400 the purchase could
not be verified (wrong product, another app, refunded, expired, a sandbox
purchase from an account not allowed one); 403 it belongs to another account;
409 it is still pending with the store; 503 the store cannot be reached or is
not configured on the server, so try again later. A 503 never grants anything.

## `GET /v1/app-config`

Signed in **or not** (send the token if you have one). Blanket per-IP limit only.

```json
{
  "flags": {
    "billing.plans.visible": false,
    "analytics.enabled": true,
    "analytics.sample_rate": true
  },
  "values": { "analytics.sample_rate": 100 },
  "min_supported_app_version": "1.0.0",
  "billing_catalog_version": 1
}
```

Flags are evaluated for the caller (allowlists need a signed-in caller). A flag
change reaches every server within 30 seconds. Credits have no flag: they are
always on. `billing.plans.visible` is the only billing flag.

## `GET /v1/billing/wallet`

60 requests a minute per user.

```json
{
  "balance": 60,
  "held": 0,
  "available": 60,
  "debt": 0,
  "expiring_soon": [
    {
      "kind": "welcome",
      "remaining": 60,
      "expires_at_unix_seconds": 1767225600,
      "next_decay_at_unix_seconds": 1762387200,
      "next_decay_credits": 6
    }
  ]
}
```

`balance` is every open credit; `held` is reserved for creations in progress;
`available = balance - held`. `expiring_soon` lists lots that expire or decay in
the next 14 days. The first call by a user at hosting level (Level 3) grants the
welcome credits, once per person.

## `GET /v1/billing/ledger?cursor=&page_size=`

60 requests a minute per user. Newest first. `page_size` 1-100, default 30.
`cursor` is the previous page's `next_cursor`, opaque; an empty `next_cursor`
means there are no more pages. A malformed cursor is 400.

```json
{
  "entries": [
    {
      "id": 812,
      "delta": -10,
      "held_delta": 0,
      "reason": "capture",
      "ref_type": "meetup",
      "ref_id": "5d1c...",
      "balance_after": 50,
      "created_at_unix_seconds": 1761300000
    }
  ],
  "next_cursor": "ODEx"
}
```

`reason` is one of `grant`, `hold`, `capture`, `release`, `decay`, `expire`,
`refund`, `reversal`, `admin_adjust`.

## `POST /v1/billing/quote`

60 requests a minute per user. The body is exactly what the user chose; any other
field (a price, a user id) is refused with 400.

```json
{ "capacity": 6, "window_start_unix_seconds": 1761400000 }
```

```json
{
  "cost": 17,
  "would_cost": 17,
  "breakdown": { "base": 10, "people": 4, "lead_time": 3 },
  "price_version": 1,
  "covered_by_plan": false,
  "balance_available": 60,
  "limits": { "max_capacity": 20, "max_advance_days": 14 },
  "credits_enforced": true
}
```

`cost` is what creating will charge: 0 inside a plan's quota (`covered_by_plan`).
`would_cost` is the price list's answer regardless, so the UI can show what a plan
saves. A capacity or start time outside `limits` is 400. `credits_enforced` is
always `true` (credits have no switch); it is kept so the response shape is
stable.

Default prices (`billing.price_rules` version 1): 10 credits for up to 4 people,
2 per person above 4; plus 0 within 48 hours, 3 up to 7 days, 6 up to 14 days,
10 up to 30 days (30 days needs a plan).

## `GET /v1/billing/entitlements`

60 requests a minute per user.

```json
{
  "plan_code": "pro",
  "plan_status": "active",
  "period_end_unix_seconds": 1764000000,
  "limits": { "max_capacity": 30, "max_advance_days": 30 },
  "meetups_included": 10,
  "meetups_used": 3,
  "credits_enforced": true
}
```

Without a plan `plan_code` is empty and the limits are 20 people and 14 days.
`credits_enforced` is always `true`. The app should read its capacity stepper
and date picker limits from here.

## `POST /v1/meetups` (changed)

Two body fields and one header. The fields are optional on the wire, so old
builds still parse, but a charged create without `expected_cost` is refused:

| | Type | Meaning |
|---|---|---|
| `expected_cost` | integer | The `cost` from the quote the user saw |
| `price_version` | integer | The quote's `price_version` |
| `Idempotency-Key` header | 1-128 printable ASCII characters | Retries with the same key return the original meetup and charge nothing more. If the create failed, retrying the **same** request with the same key reserves afresh; a **different** request under that key is 409 `idempotency_key_reused`. A malformed key is 400 |

Every create is charged: an old build gets 426; a missing or stale
`expected_cost` gets 409 `price_changed`; too few credits get 402. On success the
credits are held and captured moments later; if the create fails they are released.

Refunds are automatic: cancelling 24 hours or more before the start refunds in
full, later cancellations nothing; a meetup that ends with nobody accepted refunds
half. At most 3 refunds per 30 days, counting cancellations that were released
before they were charged. A full refund also cancels any debt that meetup's own
charge created. Refunded credits return to the lots they came
from, with their original expiry.

## Purchases (plan 29B)

### The account token

Every purchase must carry an account token, so a receipt cannot be replayed
on another account: on iOS pass it as `appAccountToken`, on Android as
`obfuscatedAccountId`. It is the UUIDv5 of the user id under the namespace
`2cea7eda-3ade-4a4a-8872-aba93a04a532`, and the catalog returns it ready-made
(`app_account_token`) for a signed-in caller. A purchase without it, or with
another user's, is refused with 403.

### `POST /v1/billing/purchases/verify`

10 requests a minute per user. Send it after the store says the purchase
succeeded, and finish the store transaction only after this returns 200
(the existing `PurchaseFlowController` rule). The body is exactly what the
store gave; any other field is refused with 400.

```json
{ "platform": "ios", "product_id": "credits_120", "token": "<StoreKit 2 signed transaction, or the Android purchase token>" }
```

```json
{
  "kind": "consumable",
  "product_id": "credits_120",
  "credits_granted": 120,
  "already_processed": false,
  "wallet": { "balance": 180, "held": 0, "available": 180, "debt": 0, "expiring_soon": [] },
  "subscription": { "status": "none", "auto_renew": false, "entitled": false }
}
```

Sending the same purchase again (a retry, a restored transaction) returns the
same result with `already_processed: true` and grants nothing. Purchased
credits never expire. On Android the server consumes or acknowledges the
purchase with Google itself, so the app must not; on iOS the app finishes the
StoreKit transaction as usual.

For a subscription, `kind` is `subscription`, `credits_granted` is 0 and
`subscription` shows the plan now in force.

### `GET /v1/billing/subscription`

60 requests a minute per user.

```json
{
  "status": "active",
  "plan_code": "pro",
  "platform": "ios",
  "product_id": "premium_monthly",
  "current_period_end_unix_seconds": 1764500000,
  "auto_renew": true,
  "entitled": true
}
```

`status` is `none`, `active`, `grace_period`, `past_due`, `canceled`, `expired`
or `revoked`. `entitled` is the one to act on: whether the plan applies right
now (active in its period, or in a grace period that has not ended).

### `GET /v1/billing/catalog`

Signed in or not. 60 requests a minute per signed-in user, and the blanket
per-IP limit otherwise.

```json
{
  "catalog_version": 1,
  "credit_packs": [
    { "product_id": "credits_50",  "credits": 50,  "bonus": 0,  "sort": 1 },
    { "product_id": "credits_120", "credits": 120, "bonus": 20, "badge": "popular", "sort": 2 },
    { "product_id": "credits_300", "credits": 300, "bonus": 75, "badge": "best_value", "sort": 3 }
  ],
  "plans_visible": true,
  "plans": [
    { "code": "pro", "product_ids": { "ios": "premium_monthly", "android": "premium_monthly" },
      "period": "month", "title": "TieHere Pro", "perks": ["10 meetups a month included", "..."], "featured": false },
    { "code": "pro", "product_ids": { "ios": "premium_yearly", "android": "premium_yearly" },
      "period": "year", "title": "TieHere Pro", "perks": ["..."], "featured": true }
  ],
  "legal": { "terms_url": "https://...", "privacy_url": "https://..." },
  "app_account_token": "5f0c..."
}
```

There are no prices, ever: show the store's own localised price for each
product id, and skip any product the store does not return. `credits` is
everything a pack grants, `bonus` the part of it to show as a bonus.
`plans` is empty while `plans_visible` is false (`billing.plans.visible` for
this caller); turning the flag on shows the plans with no app update.
`app_account_token` is only present for a signed-in caller. Refetch when
`catalog_version` (also in `/v1/app-config`) changes.

### Store webhooks

`POST /v1/billing/webhooks/apple` (App Store Server Notifications V2,
`{"signedPayload": "..."}`) and `POST /v1/billing/webhooks/google` (Pub/Sub
push of Real-time Developer Notifications, with its OIDC token in
`Authorization`). Not for the app. No session; the body is capped at 64 KB and
the per-IP limit applies.

Each is verified before anything in it is read: Apple's signature chain
against Apple's root, the Pub/Sub token against Google's keys, the audience
and the push service account. A failure is 401 and writes nothing. Each
notification is applied once (by Apple's `notificationUUID`, Pub/Sub's
message id); a redelivery is 200 and changes nothing. A notification about a
purchase this server never verified is acknowledged and ignored.

| Store event | Effect |
|---|---|
| Subscribed, renewed, recovered, restarted | `active`, period end moved forward |
| Failed to renew with a grace period / in grace period | `grace_period` (still entitled until the grace ends) |
| Failed to renew, on hold, paused | `past_due` (not entitled) |
| Expired, grace period expired | `expired` |
| Refund or revoke of a subscription; Google voided subscription | `revoked` |
| Auto-renew turned off or on (Apple renewal status, Google canceled) | `auto_renew` only |
| Refund of a credit pack (Apple `REFUND`, Google voided one-time product) | The pack's remaining credits are removed and what was already spent becomes `debt`, which blocks creating meetups (402 `credits_debt`) until the next grant pays it off |

A change of entitlement is published as `subscription.activated` or
`subscription.deactivated` through billing's outbox.
