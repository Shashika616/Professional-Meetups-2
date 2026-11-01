# Security and scalability review, 2026-11-01: everything Plan 29 added

Scope: the working tree after 29A to 29F.
- **Backend:** the `billing` module, store verification (Apple, Google, the fake),
  webhooks, the `analytics` module, the daily report, email attachments, and every new
  gateway route and gRPC service.
- **App:** the credits, purchase and analytics code in the Flutter app.

Method:
- read the code against plan 29 §5 (OWASP API Top 10 2023 and MASVS);
- ran the existing tests;
- ran `govulncheck` and `gosec` on the new code;
- ran `EXPLAIN (ANALYZE, BUFFERS)` on seeded data (100,000 accounts, about a million
  events a day, a million ledger rows).

Every fix below has a test that failed before it. Nothing is deployed.

Earlier reviews: `docs/security-review-2026-10-01.md`, `docs/security-review-2026-10-21.md`. Plan 29's own earlier
fixes are in the 29B report ("Review": R1 token in error URLs, R2 stale webhooks
applied, R3 "already consumed" matched on wording), all closed then.

## 0. Status

| Finding | Severity | Status | Tracker |
|---|---|---|---|
| S-1 Google RTDN accepted without a service-account check in production | Medium | **Fixed** | #97 |
| S-2 Store webhooks throttled at 20 a minute per IP | Low | **Fixed** | #97 |
| S-3 Analytics consent route had no per-user limit | Low | **Fixed** | #97 |
| S-4 Background statements under the 10-second request backstop | Medium (availability) | **Fixed** | #98 |
| S-5 excelize v2.11.0: two vulnerabilities reachable from our code | Medium (dependency) | **Fixed** (pinned to a fixed commit) | #98 |
| S-6 Anonymous analytics can be inflated by rotating install ids | Low | Accepted, bounded | #99 |
| S-7 SMTP error text may echo a report recipient's address into logs and `report_runs.detail` | Low | **Fixed** | #97 |
| S-8 `golang.org/x/net` v0.60.0: two advisories, not reached | Info | Open: upgrade to v0.62.0 once it is two weeks old (after 2026-11-10) | #99 |
| S-9 Rate limits are per gateway instance (existing #81) | Low | Open (unchanged, applies to the new routes too) | #81 |

## 1. Findings

### S-1 Google RTDN without the service account (Medium) — fixed

`store/google/oidc.go` checks a push token's signature, issuer and audience, and
the service account only when `GOOGLE_PUBSUB_PUSH_SERVICE_ACCOUNT` is set. The
audience is a value the subscriber chooses. Anyone can create a Pub/Sub push
subscription aimed at our URL, with our audience and their own service account, and
Google signs the token, so without the account check production accepted pushes it
did not send.

The damage is bounded: a notification only makes billing re-read the purchase from
the Android Publisher API, so nothing can be granted. But it is an unauthenticated
trigger of store calls.

**Fix:** in production, no service account means no Google webhook (503, logged at
start-up), exactly as a missing audience already did.

**Test:** `TestProductionGooglePushRequiresTheServiceAccount`.

### S-2 Store webhooks throttled (Low) — fixed

`/v1/billing/webhooks/{apple,google}` fell under the blanket 20-per-minute per-IP
limit. Apple and Google send from a few addresses, so a burst of renewals or refunds
would be refused and then delayed by the stores' own retry backoff (hours for Apple).

**Fix:** both routes get a 600-a-minute ceiling (they are authenticated by signature;
the ceiling only bounds abuse of the verification work).

**Test:** `TestRateLimit_StoreWebhooksAreNotThrottledAtTwenty`.

### S-3 Consent route without a per-user limit (Low) — fixed

Opting out deletes the account's analytics. With only the IP limit, one account
could ask for that delete repeatedly.

**Fix:** a per-user limit of 10 a minute.

**Test:** `TestAnalyticsConsentIsRateLimitedPerUser`.

### S-4 Background statements under the request backstop (Medium, availability) — fixed

`platform/db` sets `statement_timeout = 10s` on every connection, which is right for
requests. On seeded data (§3) three background jobs outgrow it:
- The **screens aggregate** was cancelled at 5.3 million events in a day.
- The **daily reconciliation** takes 1.6 s at a million ledger rows, so it would
  fail at about six million.
- The **archive export** streams a whole day.

A job that times out never finishes: the day is never aggregated, so it is never
archived or dropped, and the database grows.

**Fix:** aggregation, export and reconciliation run in their own transaction with
`SET LOCAL statement_timeout = '120s'`. Requests keep the 10-second backstop.

### S-5 excelize v2.11.0 (Medium, dependency) — fixed

`govulncheck` found two vulnerabilities reachable from the report code:
- **GO-2026-6688:** unbounded recursion on mutually-referencing array formulas.
- **GO-2026-6684:** a panic on malformed encrypted workbooks.

Both are reading-side bugs: we only write workbooks and never open untrusted ones,
but the symbols are reachable. Three more were imported but not reached
(GO-2026-6685, 6687, 6695). No tagged release has the fixes yet.

**Fix:** pinned to the main-branch commit `v2.11.1-0.20261003002531-6258dcebc4e2`
(2026-10-03, older than two weeks, as the dependency rule requires), which fixes all
five. Its new transitive versions: `mscfb` v1.0.8 (2026-08-19) and `efp` v0.0.2
(2026-09-21).

**Now:** `govulncheck`: 0 vulnerabilities affecting our code.

### S-6 Anonymous analytics can be inflated (Low) — accepted

Signed-out events are keyed by install id, so a script rotating install ids gets a
fresh 30-a-minute budget each time. The 300-a-minute per-IP ceiling bounds it.

What a script cannot do:
- send server events (refused from the app);
- attach an account (the server derives `user_key` from the session, never from the
  body);
- store free text (the registry allows identifiers only).

The damage is noise in screen and install counts. If it is ever seen, require a
session for analytics, or sign batches with a key from app attestation.

### S-7 SMTP errors may echo a recipient (Low) — fixed

When Gmail refuses a recipient, the SMTP reply can contain the address. That text
goes to the warning log and to `analytics.report_runs.detail`. The recipients are the
team's own addresses, set by the operator, but the rule is "no raw email in a log
line".

**Fix:** anything address-shaped is replaced with `[address]` in delivery errors
before they are logged or stored; the reason stays.

**Test:** `TestTheDailyRunIsIdempotentAndRetriesOnlyWhatFailed` (the relay's refusal
echoes the address).

### S-8 golang.org/x/net v0.60.0 (Info) — open

GO-2026-6866 and GO-2026-6860 are in packages we import but do not call. v0.60.0
predates Plan 29. The fix (v0.62.0, 2026-10-27) is younger than the two-week rule.
Upgrade after 2026-11-10. `golang.org/x/crypto/openpgp` (GO-2026-5932) is still
imported, not reached, with no fix available.

## 2. Plan 29 §5, item by item

| Risk | Checked | Evidence |
|---|---|---|
| **API1 object-level authorization** | Every billing and analytics route takes the user from the verified token; none takes a user id in its path, query or body. The monolith's gRPC services are behind the shared internal secret, so only the gateway can set `user_id` | Gateway tests forward the token's user (`TestCreateMeetupForwardsTheChargeFields`, `TestAnalyticsIngestAcceptsAnonymousAndSignedIn`, `TestAnalyticsConsent` refuses a body `user_id`); 29B's purchase tests (`403` for another account's purchase) |
| **API2 authentication** | Apple webhook: JWS chain to the pinned Apple root, verified before parsing. Google: OIDC signature, issuer, audience and (now always in production) service account. Cron and metrics tokens: constant-time compare | 29B store tests; S-1 test; `requireBearer` and the cron guard use `subtle.ConstantTimeCompare` with a length check |
| **API3 property-level authorization** | No amount, price, balance or entitlement is ever read from a client. Strict decoding (unknown fields refused) on quote, purchase verify, analytics batch and consent | `decodeStrict` / `decodeStrictBytes`; 29C's "a quote body with no money in it"; `TestAnalyticsIngestLimits` (an unknown `email` field is refused) |
| **API4 resource consumption** | Per-route limits (billing reads 60/min, verify 10/min, analytics 30/min per user or install plus 300/min per IP, consent 10/min, webhooks 600/min per IP). Body caps (quote 1 KB, consent 1 KB, webhooks 64 KB, analytics 64 KB after gzip, so no zip bombs). 50 events a batch, keyset pagination, a bounded analytics buffer, report attachments capped at 10 MB | Gateway limit tests; `TestAnalyticsIngestLimits` (51 events, 65 KB, a gzip bomb); `TestAFullBufferDropsWithoutBlocking`; `TestValidateRefusesWhatCouldInjectOrOverflow` |
| **API5 function-level authorization** | No admin HTTP route. Grants, adjustments, flags, report regeneration and seeding are CLIs (`billingadmin`, `analyticsreport`, `analyticsseed`); the seeder refuses any host but localhost | Package docs; `analyticsseed` host check |
| **API6 sensitive business flows** | Welcome credits once per verified person (fingerprint); refund cap; server-side quote and price version; idempotency keys on create; debt blocks creation; one grant per store transaction across accounts; webhooks idempotent by notification id and stale ones ignored | 29A and 29B integration tests (concurrent double capture, key reuse, refund cap, stale RTDN) |
| **API7 SSRF** | Store endpoints, the metadata server and the Cloud Storage API are constants. No URL from a request reaches an HTTP client. Report objects are named from a date only | `store/*`, `analytics/archive.go` |
| **API8 misconfiguration** | Production fails closed: no store credentials means 503; the fake store refused on Cloud Run; no analytics secret means nothing collected; no push service account means no RTDN (S-1). Flags default off except `analytics.enabled` (D8). Report recipients validated (plain addresses only, at most 20) | Config tests in `billing/config`, `analytics/config`; `TestProductionGooglePushRequiresTheServiceAccount` |
| **API9 inventory** | Every route is in `docs/api/billing.md` or `docs/api/analytics.md`; the report is in `docs/observability.md` | — |
| **API10 unsafe consumption** | Store responses checked for bundle or package, product, environment and account token. Timeouts, breaker and bounded retry on every store call. Hard-coded endpoints. Upload responses read with a size limit | 29B tests; `store/resilient.go` |
| **MASVS** | The app completes a purchase only after the server confirms it. No secrets in the app. Analytics opt-out. Identifiers only in events (a privacy test scans every event type). Release logging gated (`kDebugMode`) | 29C `purchase_flow_controller_test`; 29E `envelope_privacy_test`, `privacy_controls_page_test` |

### Also checked

- **Idempotency:**
  - meetup creation (key, price and window bound together);
  - purchases (transaction id; a token hash for Google);
  - webhooks (notification id, plus stale guards);
  - outbox redeliveries (analytics event ids derived from the outbox row);
  - analytics events (`event_id`, within a day: 29D-4);
  - the daily report (claimed by date, with only the failed delivery parts retried;
    `TestTheDailyRunIsIdempotentAndRetriesOnlyWhatFailed`,
    `TestAnEmailAlreadySentIsNotSentAgain`).
- **Concurrency:**
  - wallet operations lock the wallet row (`ledger.Do`);
  - partition maintenance is advisory-locked;
  - report runs are claimed by an `INSERT … ON CONFLICT DO UPDATE … WHERE`, with a dead
    claim taken over after 15 minutes;
  - the analytics flusher is a single goroutine;
  - `go test -race ./...` is clean.
- **Data minimisation:**
  - `store_purchases.raw` is stripped of personal data;
  - analytics stores keyed identifiers only;
  - the new `analytics.user_activity_days` (pseudonymous keys per active day, for
    WAU, MAU and cohorts) is deleted with the account and on opt-out, and kept 120
    days (`TestUserDeletionRemovesTheirData` checks it);
  - the report is aggregates only, groups of 1 to 4 accounts show as "fewer than 5",
    and a test scans every cell for keys, UUIDs and addresses;
  - the reconciliation reaches the report as counts only, never the detail, which
    names wallets.
- **Email attachments:** header injection refused (CR or LF in the subject or a
  recipient); filename allowlist; content-type allowlist (xlsx, csv, pdf); 10 MB cap;
  validation before any network call in every sender.
- **Logging:**
  - no tokens, receipts or raw emails (the logging sender logs counts and sizes,
    never addresses);
  - user ids (internal UUIDs) appear in a few billing info lines, as elsewhere in
    the codebase;
  - S-7 (relay errors echoing an address) is fixed.
- **gosec** on the new analytics, report, seed, email and CLI code: four findings, all
  false positives:
  - G115 ×2: narrowing conversions of a millisecond timestamp in the seeder and of a
    schema version the registry caps;
  - G404: the seeder's deterministic random generator, deliberate;
  - G101: the metadata-server token URL, which is not a credential.

## 3. Scalability (seeded: 100,000 accounts, 1.07M events in a day, 1M ledger rows, local Postgres 17 in Docker)

`EXPLAIN (ANALYZE, BUFFERS)`, warm cache except where the read counts show otherwise.

| Query | Time | Plan |
|---|---|---|
| Wallet (`GetWallet`) | 1.2 ms | Primary key |
| Wallet expiring lots (`ListOpenLots`) | 3.1 ms | Index |
| Quote: active plan (`GetActiveSubscription`) | 1.9 ms | Primary key |
| Quote: plan usage (`GetPlanUsage`) | 0.9 ms | Primary key |
| Ledger page (`ListLedger`, 20) | 3.5 ms | Index, keyset |
| Catalog (`ListCatalogProducts`) | 4.8 ms | Small table |
| Spend: lock lots (`LockSpendableLots`) | 5.9 ms | Index |
| Daily reconciliation (`ReconcileWallets`) | 1,645 ms | Full scan, by design (S-4) |
| Ingest flush: opt-out filter, 500 events | 0.8 ms | — |
| Ingest flush: insert, 500 events | 44 ms | 4 index updates; about 11,000 events a second per flusher |
| Aggregate screens | 2,760 ms | Day partition scan (expected) |
| Aggregate sessions | 5,621 → **4,086 ms** | Rewritten to one pass (three subqueries over a materialised CTE before) |
| Aggregate features / funnels / errors / credits | 610 / 461 / 94 / 220 ms | Index (`event_name, received_at`) |
| Aggregate abandons / bands / not-enough-then-bought | 70 / 39 / 19 ms | Index |
| Activity days / first seen | 840 / 666 ms | Day partition scan |
| Report: MAU (30 days) | 408 ms | Primary key range |
| Report: retention | 39 → 56 ms | **New index** `user_first_seen(first_day)` (was a scan of every account) |
| Report: cohort sizes | 57 → 92 ms (cold) | Same index |
| Report: cohorts | 1,075 ms | Hash join over 30 days of activity |
| Whole report, re-aggregating the day | 13.3 s | Background, once a day |

The request paths are flat at this size: the wallet, quote, ledger and catalog all
answer in under 6 ms.

The daily background work (all aggregates, about 11 s, plus the report reads, about
2 s) is fine at a million events a day. It is the part that grows. At ten million
events a day, split the aggregation by event family into separate statements, or
move to incremental hourly rollups.

The analytics ingest itself was measured in 29D: p95 1.0 ms at 200 batches a second.

## 4. Order of work

1. Before launch: set `GOOGLE_PUBSUB_PUSH_SERVICE_ACCOUNT` (S-1 refuses RTDN without it).
2. S-8: bump `golang.org/x/net` after 2026-11-10.
3. S-6: watch install-count anomalies in the daily report; require sessions if needed.
