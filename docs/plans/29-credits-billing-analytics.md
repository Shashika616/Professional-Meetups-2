# Plan 29: credits, billing and subscriptions, plus user-activity analytics

Two new modules in the modular monolith, built the same way as `auth` and `meetup` so either can be lifted out into its own service later without a redesign:

1. **`billing`**: an app-only credit wallet (welcome credits that decay, purchased credit packs, a ledger), meetup creation pricing, store purchases (Apple and Google, consumables and subscriptions), subscription entitlements, and a server-driven catalog so subscription plans can be switched on later without an app update.
2. **`analytics`**: user-activity events from the app and the backend, OpenTelemetry for traces, metrics and event logs, and a daily Excel report of how people use the app.

Plus one small platform piece both need: **remote app config and feature flags** (`internal/platform/flags`, exposed through the existing `ops` service).

Companion prompts, one per phase, run in order: `29A` to `29F` (`docs/plans/29*-claude-code-prompt.md`).

## 0. What exists today (verified 2026-10-24)

- `internal/modules/billing/` is empty. `POST /v1/billing/purchases/verify`, `GET /v1/billing/subscription` and the two webhook routes return 503 from `handlers/unavailable.go`; the Flutter client maps 503 to the free tier.
- The sibling repo `Professional-Meetups/backend/services/billing` holds a working, reviewed implementation of ADR-031 (vault): Apple JWS x509 chain verification with an embedded Root CA, Google Play Developer API verification failing closed, Apple Server Notifications V2 and Google RTDN (Pub/Sub OIDC) webhook auth, idempotent `store_purchases` and `processed_store_notifications`. About 2,100 lines to port, not rewrite.
- `meetup.subscription_cache` exists, its hand-written SQL uses an unqualified table name (V-20, tracker #69), and `IsEntitled` is never called. `TopicSubscriptionActivated/Deactivated` exist but nothing publishes them.
- Meetup creation: trust gate (Level 3 to host), capacity 1 to 20 (service and DB `CHECK`), no limit on how far ahead a meetup can be scheduled (the Flutter date picker allows 90 days), one meetup at a time under `pg_advisory_xact_lock`, `UserKeyedRateLimit` 10 per hour. `meetups_postgres.go Create` owns its own transaction; the only in-transaction hook is `ScheduleGuard`.
- Flutter: `PremiumPage` with product ids `premium_weekly/monthly/yearly`, `PurchaseFlowController` that completes a store transaction only after the server confirms (keep this), `buyNonConsumable` only. No remote config, no analytics, no `NavigatorObserver`, 51 imperative routes without names.
- Observability: Prometheus registry; `/metrics` on the gateway only (token-protected); the monolith's metrics are never scraped; request id not forwarded gateway to monolith; OpenTelemetry only as indirect dependencies.
- Hosting: Cloud Run `minScale: 0`, Cloud Scheduler calls `POST /internal/cron/tick`; Supabase Postgres. Latest migration `0024`.

## 1. Rules that apply to every phase

- Working tree only. No commit, push, deploy, `gcloud`, or production database. Migrations start at `0025`.
- Keep test users, seeded test emails and the scoped OTP bypass exactly as they are (`TESTING-NOTES.md`). Test accounts are added to the flag allowlists below so hidden features can be tested in production.
- **Premium never sells trust** (vault Revenue Model guardrail). Credits and plans never bypass a trust gate, verification, safety rule or report. Hosting still needs Level 3.
- **The server decides everything that costs or grants credits.** The client never sends an amount, a price, a balance or an entitlement; it sends what the user chose (capacity, start time) and the server prices it.
- Integer credits only, never floating point. Time from the server clock only.
- Every money-like write is idempotent (an idempotency key with a unique constraint), atomic (one transaction), and auditable (append-only ledger).
- Module boundaries: each module owns its Postgres schema (`billing.*`, `analytics.*`), its sqlc entry, `config/` package, proto (`proto/billing/v1`, `proto/analytics/v1`) and gRPC server. No cross-schema SQL, no foreign keys across schemas. Cross-module calls go through an interface the **consumer** defines (port), implemented by an adapter in `cmd/monolith/wiring.go`, so it can become a gRPC client later. Reliable cross-module effects go through a transactional outbox, never the in-process bus alone.
- Every fix and feature ships with tests; money paths get concurrency tests against real Postgres with `-race`.
- No admin HTTP surface. Admin actions (grant credits, set enterprise plan, change flags) run through a CLI (`cmd/billingadmin`) against the database, and every action is written to the ledger or an audit table with the operator name.

## 2. Remote config and feature flags

Table `ops.feature_flags` (or the schema the `ops` service already uses): `key TEXT PK`, `enabled BOOL`, `rules JSONB`, `updated_at`, `updated_by`. Rules, evaluated in order, first match wins: user-id allowlist, email-domain allowlist (for the `.test` fixtures), minimum app version, percentage rollout by `hash(flag_key || user_id) % 100`. Evaluation is a pure function with table tests. Flags are cached in-process for 30 seconds.

Flags introduced by this plan:

| Key | Default | Purpose |
|---|---|---|
| `billing.plans.visible` | off, test accounts allowlisted | Show subscription plans on the Premium page |
| `analytics.enabled` | on | Accept and record events |
| `analytics.sample_rate` | 100 | Client-side sampling percent per event family |

**Credits have no flag (decided 2026-10-25).** Hosts use and buy credits from day one; creating a meetup always costs credits (or plan quota). Only subscription plans, which launch later, sit behind a flag. The `credits.enforced` and `billing.credit_packs.visible` flags first planned here were dropped.

Endpoint `GET /v1/app-config` (authenticated and anonymous variants): returns evaluated flags, `min_supported_app_version`, and the billing catalog version. The client sends `X-App-Version` and `X-Platform` on every request.

**Old app versions.** A create-meetup call from an app version older than the first version with credits UI returns `426` with "Update TieHere to host a meetup." Old versions never get silently charged.

## 3. Billing module

### 3.1 Data model (schema `billing`)

| Table | Purpose and key constraints |
|---|---|
| `wallets` | One row per user: `balance BIGINT` (sum of open lots), `held BIGINT` (open holds), `version`. `CHECK (balance >= 0 AND held >= 0)`; `debt BIGINT` separate, only set by refund reversals (3.6) |
| `credit_lots` | Every grant is a lot: `kind` (`welcome`, `purchase`, `promo`, `refund`, `admin`), `initial`, `remaining`, `granted_at`, `expires_at` (NULL for purchased), decay policy columns (`decay_percent`, `decay_every`, `decay_periods_applied`, `next_decay_at`), `source_ref` (purchase id, admin action id). Index `(user_id, expires_at NULLS LAST, granted_at) WHERE remaining > 0` |
| `ledger_entries` | Append-only, one row per change: `delta`, `reason` (`grant`, `hold`, `capture`, `release`, `decay`, `expire`, `refund`, `reversal`, `admin_adjust`), `lot_id`, `hold_id`, `ref_type`, `ref_id`, `balance_after`, `idempotency_key`. Unique `(user_id, idempotency_key)`. A trigger rejects `UPDATE` and `DELETE` |
| `holds` | Try-confirm-cancel reservations: `kind` (`credits`, `plan_quota`), `amount`, `state` (`held`, `captured`, `released`), `expires_at`, `idempotency_key` unique per user, `meetup_id` once known |
| `hold_allocations` | Which lots a captured hold drew from and how much, so refunds return credits to the original lots |
| `price_rules` | Versioned pricing documents (JSON validated on load), `effective_from`, one active version |
| `plans` | Plan catalog: `code`, store product ids per platform, `period`, `meetups_included`, `max_capacity`, `max_advance_days`, `active` |
| `subscriptions` | One row per user: `plan_code`, `status` (`active`, `grace_period`, `past_due`, `canceled`, `expired`, `revoked`), `platform`, `original_transaction_id`, `current_period_start/end`, `auto_renew` |
| `plan_usage` | `(user_id, period_start)` with `used`; quota holds count against it |
| `store_purchases` | Every verified store transaction: `platform`, `transaction_id` (Apple `transactionId`, Google `orderId` and purchase token hash), `product_id`, `kind` (`consumable`, `subscription`), `app_account_token`, `verified_at`, `raw` JSONB (no personal data), `consumed_at`. Unique `(platform, transaction_id)` |
| `processed_store_notifications` | Webhook idempotency ledger (ported) |
| `welcome_grants` | Unique `user_id` and unique `identity_fingerprint` (HMAC of the verified phone or personal email from auth) so one person cannot farm welcome credits with several accounts |
| `billing_outbox` | Outbox for `credits.changed`, `subscription.activated/deactivated`, analytics domain events |
| `refund_log` | For refund caps and audits |

### 3.2 Algorithms

- **Spend order: expiring first.** Allocate a capture across open lots ordered by `expires_at NULLS LAST, granted_at` (earliest expiry first, purchased credits last), touching only as many lots as needed (O(k) for k lots used), all under `SELECT ... FOR UPDATE` of the wallet row, which serialises spends per user.
- **Decay of welcome credits.** Default 10% of the original amount every 7 days, so the lot is gone after 10 weeks. Use the cumulative formula `remaining_allowed(k) = initial - floor(initial * percent * k / 100)` so rounding never drifts. Decay is materialised by a sweep (claims lots with `next_decay_at <= now()` in batches with `FOR UPDATE SKIP LOCKED`, idempotent by `(lot_id, period_index)` in the ledger). The spend path also applies any due decay for that user inside its own transaction, so a spend is always priced against the true balance between sweeps.
- **Holds.** `Reserve` takes credits or plan quota out of availability (`held += amount`) without spending. `Capture` turns the hold into ledger spends with allocations. `Release` returns it. Holds expire after 2 hours (configurable) by sweep. A capture that arrives after its hold expired re-spends if the balance allows; if it does not, it records debt and an alert, and the reconciliation report lists it. This is the microservice-safe version of "charge and create in one transaction".
- **Reconciliation.** A daily sweep checks, per user, that `wallet.balance == sum(lots.remaining)`, `held == sum(open holds)`, and the ledger replays to the same balance. Any mismatch is logged, counted and listed in the daily report.

### 3.3 Pricing

A pure function `Price(rules, input) Quote` with table-driven and property tests (cost never decreases when capacity or lead time increases).

Default rule document (all numbers are data in `price_rules`, changeable without a deploy):

- Base 10 credits, covering the host plus up to 3 people (capacity up to 4).
- Plus 2 credits for each person above 4.
- Lead time (from now to `window_start`): within 48 hours +0; 3 to 7 days +3; 8 to 14 days +6; 15 to 30 days +10 (plan only).
- Inside an active plan's quota: 0 credits, one quota unit.

`Quote` returns `cost`, `breakdown` (base, people, lead time), `price_version`, `covered_by_plan`, `balance_available`, `limits` (max capacity and max advance days for this user).

### 3.4 Entitlements and limits

| | No plan | Plan (monthly or yearly) |
|---|---|---|
| Max capacity | 20 (unchanged) | 30 |
| Max advance scheduling | 14 days | 30 days |
| Meetups without credits | 0 | 10 per billing period, then credits apply |
| Cost | price rules | 0 within quota |

`GET /v1/billing/entitlements` returns these so the Flutter date picker and capacity stepper read their limits from the server instead of hard-coded 90 days and 20 people. Migration changes the capacity `CHECK` to 1 to 30; the service enforces the per-user limit. Joining a meetup is always free and never touches billing.

### 3.5 Meetup creation flow

The meetup module gets a port it owns:

```
type CreationCharger interface {
    Quote(ctx, userID, capacity, windowStart) (Quote, error)
    Reserve(ctx, userID, quote, idempotencyKey) (HoldID, error)
    Release(ctx, holdID) error
}
```

1. The client calls `POST /v1/billing/quote` on the review step and shows the cost. The create request carries `expected_cost`, `price_version` and an `Idempotency-Key` header.
2. `meetup.Create` checks trust and validation, calls `Quote`; if the server cost differs from `expected_cost`, it returns 409 `price_changed` with the new quote.
3. `Reserve` (credits or plan quota). Not enough returns 402 `insufficient_credits` with `{cost, available, shortfall}`; add `apperror.ErrPaymentRequired` mapped to 402.
4. The existing create transaction inserts the meetup with `creation_key` (unique per host) and `charge_hold_id`, and writes `meetup.created` with the hold id to a meetup outbox table **in the same transaction**.
5. The outbox poller calls `billing.Capture(hold_id, meetup_id)`; capture is idempotent. If the transaction fails, `Release` runs immediately; the hold TTL is the backstop.
6. Retrying the same request with the same `Idempotency-Key` returns the original meetup and charges nothing more.


### 3.6 Refunds and reversals

Refund policy is data, owned by billing, applied when meetup writes `meetup.cancelled` or `meetup.closed` (with `accepted_count`, `window_start`, `cancelled_at`) to its outbox in the cancel and close transactions:

- Host cancels 24 hours or more before start: full refund (credits back to the original lots with their original expiry; plan quota restored).
- Host cancels less than 24 hours before start: no refund.
- Meetup ends with no accepted participants: 50% refund.
- At most 3 refunds per user per 30 days (anti-abuse); refunds beyond that are logged and skipped.
- Account deletion: the wallet is closed, remaining purchased credits are recorded in the audit table, and no refund is owed by the app (store refunds go through Apple and Google).

Store refunds and chargebacks (Apple `REFUND`, Google voided purchases and RTDN): remove the remaining credits of that purchase lot; if some were already spent, record `debt`, which future grants pay off first. Creation is blocked while debt exists.

### 3.7 Store purchases (consumable credit packs and subscriptions)

Port the sibling repo's `verify` and `webhookauth` packages into `internal/modules/billing/store/` behind one interface (`StoreVerifier` with `Verify(ctx, platform, productID, token) (VerifiedTransaction, error)`; adapters `apple`, `google`, and a `fake` for tests and local runs). Breaker plus bounded retry around every store call.

- **Account binding.** The client passes `applicationUserName` = UUIDv5 of the user id (`appAccountToken` on Apple, `obfuscatedAccountId` on Google). The server rejects a verified transaction whose token does not match the caller. This stops replaying one person's receipt on another account.
- **Consumables.** Apple: verify the signed transaction through the App Store Server API by transaction id. Google: `purchases.products.get`, then acknowledge and consume server-side (`purchases.products.consume`) after the grant commits, so the pack can be bought again and is never auto-refunded for missing acknowledgement. The client calls `buyConsumable(autoConsume: false)` and completes the transaction only after the server confirms.
- **Grant.** One transaction: insert `store_purchases` (unique key makes a duplicate verify a no-op that returns the original result), create a `purchase` lot that never expires, write the ledger entry, enqueue `credits.changed`.
- **Subscriptions.** Activation, renewal, grace period, expiry, refund and revoke through verify plus webhooks, as in ADR-031. Publish `subscription.activated/deactivated` through `billing_outbox` (not the lossy bus). Fix V-20 (schema-qualified `meetup.subscription_cache`) on the way.
- **A paid purchase is never refused.** If plans are hidden by flag but a verified subscription arrives, grant it and alert.
- Webhooks: `POST /v1/billing/webhooks/apple` and `/google`, signature or OIDC verified before any state change, idempotent, size-capped, rate-limited per source.

### 3.8 Server-driven catalog

`GET /v1/billing/catalog` returns, already filtered by the caller's flags:

```
{ "catalog_version": 7,
  "credit_packs": [ {"product_id": "credits_50", "credits": 50, "bonus": 0, "badge": null, "sort": 1}, ... ],
  "plans_visible": false,
  "plans": [ {"code": "pro", "product_ids": {"ios": "premium_monthly", "android": "premium_monthly"},
              "period": "month", "title": "...", "perks": ["..."], "featured": true}, ... ],
  "legal": {"terms_url": "...", "privacy_url": "..."} }
```

Prices are never in this payload; the app always shows the store's localised price for the product ids it receives. The Premium page and the buy-credits page render whatever the catalog returns, so turning on `billing.plans.visible` shows the plans to everyone with no app update. Products the store does not return are skipped.

### 3.9 Endpoints

| Route | Auth | Limit |
|---|---|---|
| `GET /v1/billing/wallet` (balance, held, lots expiring soon, debt) | user | 60/min |
| `GET /v1/billing/ledger?cursor=` (keyset paginated history) | user | 60/min |
| `POST /v1/billing/quote` | user | 60/min |
| `GET /v1/billing/entitlements` | user | 60/min |
| `GET /v1/billing/catalog` | optional | 60/min |
| `POST /v1/billing/purchases/verify` | user | 10/min per user |
| `GET /v1/billing/subscription` | user | 60/min |
| `POST /v1/billing/webhooks/apple`, `/google` | signature | per source |

User id always comes from the JWT. Responses never include another user's data.

## 4. Analytics module

### 4.1 What "the full picture" needs

The daily report must answer: what people use most and least, where they spend time, where they get stuck, which flows they abandon, which features nobody touches, and what they spend credits on. That needs five kinds of data:

1. **Sessions**: app open, foreground and background, session start and end (a new session after 30 minutes in the background).
2. **Screens**: `screen_viewed` and `screen_left` with `duration_ms`, so time on screen, exits and bounces can be computed.
3. **Actions**: `cta_tapped` for a defined catalogue of controls (not every tap), search, filters, toggles.
4. **Flows (funnels)**: `flow_started`, `flow_step_viewed`, `flow_step_completed`, `flow_completed`, `flow_abandoned` with a `flow_id` and step names, for onboarding, verification to Level 2, hosting unlock, schedule a meetup (5 steps), join a meetup, review, buy credits, subscribe, SOS.
5. **Friction**: `error_shown` (screen, kind), `api_error` (route, status class), timeouts, `rage_tap` (3 or more taps within one second on the same spot without navigation), long dwell without action on a form step.

Server-side domain events add the facts the app cannot know: `meetup_created`, `join_requested`, `request_accepted`, `meetup_completed`, `credits_granted/spent/refunded/expired`, `purchase_verified`, `subscription_changed`.

### 4.2 Event standard

Envelope, aligned with OpenTelemetry semantic conventions where they exist and CloudEvents-style identity:

| Field | Notes |
|---|---|
| `event_id` | UUIDv7 generated on the device; deduplication key |
| `event_name` | `snake_case` object_action from the registry |
| `schema_version` | integer per event name |
| `occurred_at`, `received_at` | device time and server time; reports use server time, events more than 7 days off are rejected |
| `session.id`, `install_id` | random ids, no device identifiers (no IDFA or Android ID) |
| `user_key` | HMAC-SHA256 of the user id with an analytics secret; never the raw id |
| `app.version`, `os.name`, `os.version`, `device.class`, `locale` | coarse only |
| `screen`, `flow_id`, `flow_step` | from the screen catalogue |
| `attributes` | typed, allowlisted per event in the registry; at most 20 keys; strings at most 100 characters; no free text |

The registry (`internal/modules/analytics/registry/events.yaml`, embedded) lists every event name, its schema version, allowed attributes and types. Unknown events and attributes are dropped and counted. The same registry generates the Dart constants so client and server cannot drift.

Never collected: names, emails, phones, free text, meetup titles or labels, exact coordinates, IP addresses (used only for rate limiting, not stored), store receipts.

### 4.3 Ingest and storage

- `POST /v1/analytics/events`, gzip accepted, at most 50 events and 64 KB per batch, 30 batches per minute per user or install, anonymous allowed for pre-sign-in screens.
- The handler validates against the registry and hands accepted events to a bounded in-process buffer flushed by `COPY` into Postgres every few seconds or 500 events, and on shutdown. When the buffer is full, events are dropped and counted (analytics is best-effort; billing is exactly-once).
- `analytics.events` is range-partitioned by `received_at` day, BRIN index on `received_at`, B-tree on `(event_name, received_at)`. A sweep creates partitions three days ahead and drops partitions older than the raw retention.
- Supabase storage is limited on the free plan, so raw events stay 14 days in Postgres (configurable). Before a partition is dropped, the daily job writes it as gzip NDJSON to the existing Cloud Storage bucket (`analytics/raw/YYYY/MM/DD.ndjson.gz`), which is the archive that Kibana, BigQuery or Grafana can load later. Daily aggregates (`analytics.daily_*`) are kept.
- User deletion deletes that user's events by `user_key` and drops them from aggregates that are per user.
- Opt-out: a toggle in Privacy Controls; when off, the client sends nothing and the server drops anything carrying that `user_key`.

### 4.4 OpenTelemetry

- Backend tracing: OTel SDK with `otelhttp` on the gateway, `otelgrpc` on both sides (W3C `traceparent` replaces the lost request id between gateway and monolith), a pgx tracer, and spans around store calls and outbox processing.
- Metrics: keep the Prometheus registry; add business counters (`credits_spent_total`, `purchases_verified_total{platform,kind}`, `analytics_events_ingested_total{family}` with low-cardinality labels only); expose the monolith's registry through the gateway's token-protected `/metrics`.
- Events: each accepted analytics event is also emitted as an OTel log record (`event.name` attribute) through the OTel Logs SDK.
- Exporters configurable by env: `none` (default on the free tier), `stdout`, or `otlp` to an OpenTelemetry Collector. Pointing the collector at Elasticsearch and Kibana, Prometheus or Grafana later is a configuration change, not a code change.
- The Flutter app does not ship an OTel SDK (no mature mobile Dart SDK is assumed); it sends the event envelope above, which the server converts.

### 4.5 Daily Excel report

Generated by the cron tick once per day after 06:00 Asia/Colombo for the previous day (idempotent by date in `analytics.report_runs`), with `excelize`, then emailed to `ANALYTICS_REPORT_RECIPIENTS` (needs attachment support in the email sender) and stored in Cloud Storage `analytics/reports/YYYY-MM-DD.xlsx`.

| Sheet | Contents |
|---|---|
| Summary | DAU, WAU, MAU, new sign-ups, sessions, median and mean session length, D1 and D7 retention, errors, credits granted, spent, expired, purchased; comparison with the previous day and the same day last week |
| Screens | Per screen: views, unique users, median and p90 time on screen, exits (last screen of a session), bounces (left within 3 seconds) |
| Features | Per catalogued action: users, uses, share of DAU; a "not used in 7 days" list |
| Funnels | Per flow and step: entered, completed, conversion, drop-off, median time between steps |
| Stuck | Errors by screen and kind, API errors by route, timeouts, rage taps, long dwell, back-and-forth loops |
| Abandoned | Flows started and not completed, the step where they stopped, whether the app was backgrounded |
| Credits and revenue | Grants, spends by price band, refunds, expiry, packs bought, insufficient-credit events and whether a purchase followed, reconciliation mismatches |
| Cohorts | Weekly sign-up cohorts by week of activity |
| Glossary | Exact definition of every metric |

## 5. Security checklist (OWASP API Top 10 2023 and MASVS)

| Risk | How this plan handles it |
|---|---|
| API1 broken object-level authorization | User id only from the JWT; every billing and analytics read filtered by it; tests that try another user's ids |
| API2 broken authentication | Webhooks verify Apple JWS chain and Google OIDC before parsing state; cron and metrics secrets constant-time |
| API3 property-level authorization | No client-supplied amounts, prices, balances or entitlements; strict request structs (unknown fields rejected) |
| API4 unrestricted resource consumption | Per-route limits above, body caps, batch caps, keyset pagination, bounded buffers |
| API5 function-level authorization | No admin HTTP routes; CLI only |
| API6 sensitive business flows | Welcome credits once per verified person; refund cap; quote recomputed server-side; idempotency keys; debt blocks creation after chargebacks |
| API7 SSRF | Store endpoints hard-coded; no user-supplied URLs |
| API8 misconfiguration | Fail closed without store credentials in production; flags default off |
| API9 inventory | Every new route listed in `docs/api/billing.md` and `docs/api/analytics.md` |
| API10 unsafe consumption of APIs | Validate store responses (bundle id, product id, environment, account token), timeouts, breaker |
| MASVS | Purchase completed only after server verification; no secrets in the app; analytics opt-out; no PII in events; release logging gated |

## 6. Store and legal constraints (Shashika to confirm before launch)

- Apple App Review Guideline 3.1.1 says credits bought through in-app purchase must not expire. In this plan only free welcome credits decay; purchased lots have no expiry. Keep it that way.
- A first in-app purchase or subscription on iOS has to be submitted for review with an app version. To show subscriptions later without an app update, submit the subscription products with the first release that contains this code, and give App Review a test account that is on the `billing.plans.visible` allowlist. Apple also asks that apps contain no hidden features (Guideline 2.3.1), so describe the server flag in the review notes. Check the current wording of both guidelines at submission time.
- Subscription screens need the price, period, auto-renew terms, and links to terms and privacy (Guideline 3.1.2); the catalog carries the links.
- Google Play requires purchases to be acknowledged within three days or they are refunded; the server acknowledges and consumes after the grant.
- Activity analytics needs a privacy policy update (what is collected, processors, retention, opt-out) under Sri Lanka's Personal Data Protection Act, No. 9 of 2022. Get it reviewed.

## 7. Decisions (defaults used unless `docs/plans/29-decisions.md` says otherwise)

| # | Question | Default |
|---|---|---|
| D1 | When welcome credits are granted, and how many | 60 credits when the user first reaches hosting (Level 3); one grant per verified phone or personal email |
| D2 | Decay | 10% of the original amount every 7 days; gone after 10 weeks |
| D3 | Price rules | Section 3.3 |
| D4 | Free limits | Capacity 20, advance 14 days (today the app allows 90 days and the backend has no limit; this is a behaviour change) |
| D5 | Plan | One plan `pro`, monthly and yearly, product ids `premium_monthly` and `premium_yearly` (existing), weekly dropped; 10 meetups, 30 people, 30 days |
| D6 | Credit packs | `credits_50`, `credits_120` (+20 bonus), `credits_300` (+75 bonus); prices set in the stores |
| D7 | Refund policy | Section 3.6 |
| D8 | Analytics consent | On by default with an opt-out toggle and a privacy policy update |
| D9 | Retention | Raw events 14 days in Postgres, 13 months in the Cloud Storage archive, aggregates kept |
| D10 | Report delivery | Email attachment plus Cloud Storage copy |
| D11 | Old app versions when credits are enforced | 426 "Update TieHere to host a meetup" |

## 8. Phases

| Phase | Prompt | Scope | Done when |
|---|---|---|---|
| 29A | `29A-billing-foundations-claude-code-prompt.md` | ADRs 010 to 012, flags and `/v1/app-config`, billing schema, ledger, lots, decay, holds, pricing, entitlements, welcome grant, meetup integration, refunds, admin CLI | Concurrency tests green; creating a meetup with enforcement on charges exactly once under retries; refunds return to original lots |
| 29B | `29B-store-purchases-subscriptions-claude-code-prompt.md` | Port store verification and webhooks, consumables, subscriptions, catalog, refunds and chargebacks, V-20 | Duplicate verify grants once; replayed receipt on another account rejected; webhook replay is a no-op |
| 29C | `29C-flutter-credits-premium-claude-code-prompt.md` | App config provider, version headers, wallet and history, cost line and insufficient-credits path, buy credits, server-driven Premium page, limits from entitlements | Plans appear when the flag turns on with no rebuild; widget tests for every state |
| 29D | `29D-analytics-backend-otel-claude-code-prompt.md` | OTel tracing, metrics, logs; registry; ingest; storage and partitions; server domain events; privacy, deletion, retention, archive | Load test: 200 batches per second for 60 seconds without errors on local Postgres |
| 29E | `29E-analytics-client-claude-code-prompt.md` | Dart SDK, screen catalogue and route names, sessions, funnels, CTAs, friction signals, opt-out | Every catalogued screen and flow emits its events in tests |
| 29F | `29F-daily-report-hardening-claude-code-prompt.md` | Daily Excel report, reconciliation in the report, security review of the new code, docs, vault | Report generated from seeded data with every sheet populated; review findings fixed or tracked |

Each phase ends with `go vet ./...`, `go test -race ./...`, `flutter analyze`, `flutter test`, `dart format --set-exit-if-changed`, and a completion report `docs/plans/29X-completion-report.md`. A report says "progress" until every item in its phase has a passing test.

## 9. Things only Shashika can do

App Store Connect: consumable and subscription products, App Store Server API key, Server Notifications V2 URL, sandbox testers, review notes. Google Play Console: in-app products and subscription with base plans, Android Publisher API service account, RTDN Pub/Sub topic and push subscription, license testers. Cloud: secrets in Secret Manager, a second Cloud Scheduler job for the daily report if wanted, Cloud Storage prefix permissions for the Cloud Run service account, an OpenTelemetry Collector when dashboards are wanted. Legal: privacy policy and terms updates.
