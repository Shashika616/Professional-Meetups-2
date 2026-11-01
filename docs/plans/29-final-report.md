# Plan 29 final report: credits, billing, subscriptions and analytics

Plan 29 is complete in the working tree (29A to 29F). Nothing is committed, pushed or
deployed, and no production database was touched. Test users, seeded test emails and
the scoped OTP bypass are unchanged. The phase reports have the detail:
`29A-completion-report.md`, `29B-completion-report.md`, `29C-completion-report.md`,
`29D-completion-report.md` and `29E-completion-report.md`. This report covers 29F and
the whole plan.

## What was built

| Phase | What |
|---|---|
| 29A | Feature flags and `/v1/app-config` (with app-version headers). The `billing` module: wallet, lots (welcome decay and expiry), holds, an append-only ledger, server-side pricing, entitlements, the refund policy, daily reconciliation, `cmd/billingadmin`. Meetup creation charges credits through a hold, then a capture via an outbox, with idempotency keys. Credits have no flag |
| 29B | Store purchases (Apple App Store Server API, Google Android Publisher), the account token, one grant per transaction, Apple and Google notifications verified and applied once, refunds of spent credits as debt, subscriptions, a server-driven catalog. Fails closed without credentials |
| 29C | The app's Credits and Buy credits pages, the cost row and the not-enough-credits path in the schedule flow, a Premium page built from the catalog, consumable purchases completed only after the server confirms |
| 29D | The `analytics` module: an event registry (which also generates the Dart constants), ingest with a bounded buffer, day-partitioned storage, the Cloud Storage archive, daily aggregates, server events from the outboxes, consent and deletion. OpenTelemetry tracing, metrics and event logs, off by default |
| 29E | The app's in-house analytics client: sessions, every screen and sheet named, catalogued controls, nine funnels, friction signals, the opt-out switch in Privacy Controls |
| 29F | The daily Excel report, its schedule and delivery, email attachments, the regeneration CLI, the seeder, the security and scalability review, runbook, testing notes, the vault note |

## 29F in detail

### The report

`internal/modules/analytics/report`, built with excelize from the daily aggregates.
- **Sheets**, in plan 29 §4.5's order: Summary, Screens, Features, Funnels, Stuck,
  Abandoned, Credits and revenue, Cohorts, Glossary.
- **Layout:** each sheet has a title, a note and a frozen header row, with set column
  widths and number formats.
- **Comparisons:** against the previous day and the same day last week; a fall of more
  than 20% is red.
- **Charts:** accounts active per day over 28 days, and whole-flow conversion per
  funnel.
- **Days** are Asia/Colombo days.
- **Privacy:** aggregates only. A group of 1 to 4 accounts, or a rate computed from one,
  shows "fewer than 5". Event counts (views, sessions) are shown, because they count
  events, not people.

The Summary covers DAU, WAU and MAU; new accounts (first seen); active installs;
sessions and their median and mean length; D1 and D7 retention; errors; credits
granted, spent and expired; purchases; and reconciliation mismatches (counts only,
read from billing through a port). The Features sheet lists the catalogued controls
not used in 7 days.

### Schedule and delivery

- **The sweep:** `analytics: daily report` runs on the existing 15-minute tick. After
  06:00 Colombo it claims yesterday in `analytics.report_runs`; a run already done, or
  held by another tick, is skipped, and a dead claim is taken over after 15 minutes.
  It aggregates the day if needed, builds the workbook, emails it to
  `ANALYTICS_REPORT_RECIPIENTS` and uploads it to
  `analytics/reports/YYYY-MM-DD.xlsx`.
- **Retries:** delivery is tracked per part, so a failed email or upload is retried
  on the next tick, repeating only what failed, up to 24 attempts. Failures are
  logged, counted (`analytics_reports_total{part,outcome}`) and stored, with addresses
  redacted.
- **Regeneration:** `cmd/analyticsreport --date=YYYY-MM-DD [--out=file] [--deliver]`
  re-aggregates a day from its raw events and replaces the stored copy. It refuses a
  day that is not over (found on the device test, below).
- **Attachments:** every sender (logging, Gmail SMTP, Resend) implements
  `SendWithAttachment`. Validation runs first in each: no CR or LF in the subject or a
  recipient, a filename and content-type allowlist, a 10 MB cap.

### Schema (migration 0032)

- `analytics.user_activity_days`: the per-day active accounts behind WAU, MAU,
  retention and cohorts. Pseudonymous keys, deleted with the account and on opt-out,
  kept 120 days.
- `analytics.daily_abandon_stats` and `analytics.daily_credit_band_stats`.
- `median_step_ms` on the funnel table.
- Delivery columns on `report_runs`.
- An index on `user_first_seen(first_day)`.

Aggregation now runs per Asia/Colombo day, over the two UTC partitions each day spans;
the retention sweep aggregates both before dropping a partition.

### Seed and verify

`backend/scripts/seed-analytics.sh [accounts] [days] [end]`, through
`cmd/analyticsseed`, writes realistic synthetic activity into a **local** database
(any other host is refused), aggregates it and builds a report:
- accounts first seen across the period and returning less over time, plus installs
  that never sign in;
- sessions of screens with lifelike durations, controls, funnels with drop-off,
  friction;
- the server's credit and purchase events;
- a rare screen viewed by two accounts, so suppression has something to do.

A fortnight for 500 accounts (113,000 events) seeds in 1.7 s.

### Tests added in 29F

| Required | Test |
|---|---|
| Report from seeded data: every sheet present, totals match SQL, small groups suppressed, no personal data | `TestTheReportFromSeededDataMatchesSQL`: 300 accounts over 10 days. Checks the nine sheets, each with data. DAU, WAU, credits spent, purchases, every screen's views, the schedule funnel, the Stuck total and the top feature each equal an independent SQL query over the raw events. The rare screen shows "fewer than 5". Both charts point at their ranges. No cell holds a key, UUID or address |
| Idempotent daily run | `TestTheDailyRunIsIdempotentAndRetriesOnlyWhatFailed`: nothing before 06:00; a failed email leaves the run failed; the retry sends only the email; later ticks do nothing. `TestAnEmailAlreadySentIsNotSentAgain` |
| Regeneration overwrites cleanly | `TestRegenerationOverwritesCleanly` (the stored copy replaced, aggregates rebuilt, not doubled); `TestRegeneratingADayThatIsNotOverIsRefused` |
| Email with attachment through the logging sender | `TestTheReportMailsThroughTheLoggingSender` (and every configured sender can attach); `attachment_test.go`: injection, size, type, filename, a MIME round trip, Gmail against a capturing SMTP server |
| Also | `report/build_test.go`: suppression everywhere, the 20% colouring, frozen headers. The review's tests (§ below) |

For the key tests, I broke the code they guard and confirmed each one fails. Four
first survived:
- re-sending an email that had been sent;
- skipping the 06:00 check;
- WAU's 7-day window;
- DAU's zero versus small.

I strengthened each test until it caught its mutant.

### Security review and scalability

Full detail is in `docs/security-review-2026-11-01.md`.

**Fixed, each with a test written first:**
- **S-1:** a Google RTDN push was accepted without the service-account check in
  production; it now needs the account.
- **S-2:** the store webhooks get a 600-a-minute IP ceiling, up from 20.
- **S-3:** the consent route has a per-user limit.
- **S-4:** aggregation, export and reconciliation now run under their own 120-second
  statement limit, instead of the request path's 10-second backstop. A
  5.3-million-event day had hit it.
- **S-5:** excelize v2.11.0 had two vulnerabilities reachable from our code. It is now
  pinned to fixed commit `6258dcebc4e2` (2026-10-03), so govulncheck reports 0
  affecting our code.
- **S-7:** recipient addresses echoed in relay errors are redacted.

**Still open:**
- **S-6, accepted:** anonymous analytics can be inflated by rotating install ids,
  within the IP ceiling.
- **S-8:** `golang.org/x/net` v0.60.0 has two unreached advisories. Upgrade after
  2026-11-10 (the fix is not yet two weeks old).

**Scalability:** seeded with 100,000 accounts, a 1.07-million-event day and a million
ledger rows.
- The request paths answer in under 6 ms: wallet, quote, ledger page and catalog.
- An ingest flush inserts 500 events in 44 ms.
- A day's aggregation takes about 11 s; the sessions aggregate was rewritten from
  5.6 s to 4.1 s.
- The report's reads take at most 1.1 s; the whole report, re-aggregating the day,
  13.3 s.
- Daily reconciliation takes 1.6 s, a full scan by design.

### Device test (Pixel 8 emulator, 2026-11-01)

The local stack was rebuilt from this tree at schema 32.
- **The app:** it works unchanged, signed in as `l3.a@meetups.test`: Home, Profile,
  the Credits row (48 credits) and Privacy Controls.
- **Opting out:** the server recorded the opt-out and deleted the account's 9 stored
  events. Opting back in, new screen and tab events arrived again.
- **The report from real emulator data:** that day showed "fewer than 5" for accounts
  and viewers, with falls of more than 20% against last week in red.

**Bug found by that run and fixed (test first):** regenerating today, a day that is not
over, recorded it as aggregated and reported, so neither would have been redone once
the day ended. `RegenerateReport` now refuses today and later (`ErrDayNotOver`).

### Gates

| Gate | Result |
|---|---|
| `gofmt -l .`, `go vet ./...` | Clean |
| `go test -race -count=1 ./...` | All 40 test packages pass (local Postgres) |
| `golangci-lint run ./...` | 0 issues |
| `govulncheck ./...` | 0 vulnerabilities affecting our code |
| `gosec` on the new code | 4 findings, all triaged as false positives (review §2) |
| Migrations | 0032 up, down, up on a scratch database; schema 32, not dirty |
| `sqlc diff`, `go mod tidy` | Clean |
| Flutter (unchanged in 29F) | `flutter analyze` clean, `dart format` clean, 877 tests pass |

### Decisions

1. **Days are Asia/Colombo days** for aggregates and the report, as plan §4.5 asks.
   Raw partitions stay UTC days (the retention and archive work by partition). This
   changed 29D's aggregation; its tests pass unchanged apart from the new funnel
   column.
2. **WAU, MAU, retention and cohorts need per-account rows** (distinct counts do not
   add up across days), so `user_activity_days` exists. It holds pseudonymous keys
   only, is never printed, is deleted with the account and on opt-out, and is kept 120
   days. The privacy notes say so.
3. **"New accounts" means first seen in analytics**, not sign-ups (analytics cannot
   read the auth schema). The glossary says so.
4. **excelize is pinned to a main-branch commit** until a tagged release carries the
   security fixes (tracker #98).
5. **No second Cloud Scheduler job:** the 15-minute tick runs the report between 06:00
   and 06:15 Colombo.
6. **Back-and-forth loops** (a Stuck-sheet item in the plan) are not measured yet.

## How to switch things on in production

**Order:** backend and app together, then plans when you choose.

1. **Deploy with the 1.1.0 app release.** Credits are live the moment the backend
   serves: older builds get 426 on creating a meetup, and the 60 welcome credits,
   pricing and limits apply. The runbook (§12) has the order.
   - Run migrations 0025 to 0032 first. They are additive; the monolith refuses to
     start below schema 32.
   - Set `MIN_CREDITS_APP_VERSION` to the released build.
2. **Credit packs** need no switch. They appear once the store products exist and the
   store credentials are set (`docs/deploy/store-setup.md`, runbook §13). Until then
   purchases answer 503 and nothing is granted.
3. **Analytics:**
   - set `ANALYTICS_USER_KEY_SECRET`; without it production collects nothing;
   - optionally set `ANALYTICS_ARCHIVE_BUCKET` (with `roles/storage.objectCreator`)
     and `ANALYTICS_REPORT_RECIPIENTS`;
   - the report starts the next morning (runbook §14).
4. **Plans:** finish the store side, set `BILLING_TERMS_URL` and
   `BILLING_PRIVACY_URL`, and test with sandbox and license testers on an allowlisted
   account (`TESTING-NOTES.md`). Then:
   ```bash
   go run ./cmd/billingadmin flags set --flag billing.plans.visible --enabled true \
     --operator shashika --reason "launch plans"
   ```
   It is live within 30 seconds, with no release (runbook §15).

## Things only Shashika can do (plan 29 §9)

- [ ] **App Store Connect:** the consumable and subscription products, the App Store
  Server API key (issuer id, key id, `.p8` into Secret Manager), the Server
  Notifications V2 URL (`/v1/billing/webhooks/apple`), sandbox testers, review notes.
- [ ] **Google Play Console:**
  - the in-app products, and the subscription with its base plans;
  - the Android Publisher API service account (key into Secret Manager);
  - the RTDN Pub/Sub topic and its push subscription (`/v1/billing/webhooks/google`),
    then set both `GOOGLE_PUBSUB_PUSH_AUDIENCE` and
    `GOOGLE_PUBSUB_PUSH_SERVICE_ACCOUNT` (S-1: production refuses RTDN without the
    account);
  - license testers.
- [ ] **Cloud:**
  - secrets in Secret Manager: `ANALYTICS_USER_KEY_SECRET`, the store keys, optionally
    `METRICS_TOKEN`;
  - `roles/storage.objectCreator` for the Cloud Run service account on the bucket
    (`analytics/raw/` and `analytics/reports/`), with a lifecycle rule for
    `analytics/raw/`;
  - `ANALYTICS_REPORT_RECIPIENTS`;
  - an OpenTelemetry Collector when dashboards are wanted (`docs/observability.md`).
  - A second Scheduler job for the report is **not** needed (decision 5).
- [ ] **Legal:** update the privacy policy (analytics, using
  `docs/privacy-analytics-notes.md`, and purchases) and the terms (credits,
  subscriptions, refunds) before the release.

## Open risks

| Risk | Mitigation |
|---|---|
| Deploying the backend before the 1.1.0 app is in users' hands stops everyone on older builds from hosting | Ship together; `MIN_CREDITS_APP_VERSION` set to the released build |
| Store console setup incomplete at launch | Fails closed (503, nothing granted). The Buy credits and Premium pages show their empty states |
| Analytics secret missing or rotated | Missing: nothing collected (logged at start-up). Rotating splits every account's history; do not rotate casually |
| Aggregation grows with events per day (about 11 s at a million) | Fine for a long while. Split it or move to hourly rollups well before ten million a day |
| excelize on a pseudo-version | Move to the tagged release when it ships (#98) |
| Anonymous analytics noise (S-6) | IP ceiling; require sessions if the daily report shows anomalies |
| Analytics deduplication holds within a server day (29D-4) | Accepted: a retry across midnight can be stored twice |
| Rate limits are per gateway instance (#81) | Unchanged by plan 29; a shared limiter is tracked |
| `golang.org/x/net` advisories (S-8) | Not reached; upgrade after 2026-11-10 |
