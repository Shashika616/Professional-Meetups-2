# Claude Code prompt 29F: daily Excel report, hardening, review, docs

Read first: `docs/plans/29-credits-billing-analytics.md` (sections 4.5, 5, 6, 9), all `29A` to `29E` completion reports, `docs/api/billing.md`, `docs/api/analytics.md`, `docs/observability.md`, `backend/internal/modules/auth/email/` (the email sender).

## Goal

A daily Excel report that shows how the app is used, followed by a security and scalability pass over everything Plan 29 added.

## Hard rules

Same as the earlier phases. The report contains aggregates only: no user keys, no ids, no personal data; small groups (fewer than 5 users) are shown as "fewer than 5".

## Work, in order

1. **Report** (`internal/modules/analytics/report`): built from the daily aggregate tables with `excelize` (pinned version), sheets exactly as plan 4.5 (Summary, Screens, Features, Funnels, Stuck, Abandoned, Credits and revenue, Cohorts, Glossary), frozen header rows, column widths, number formats, conditional colouring for drops greater than 20% versus the previous week, and a chart for DAU and funnel conversion. Times in Asia/Colombo.
2. **Schedule**: the cron tick runs the report once per day after 06:00 Asia/Colombo for the previous day, idempotent by date in `analytics.report_runs`; a CLI `cmd/analyticsreport --date=YYYY-MM-DD` regenerates any day.
3. **Delivery**: add attachment support to the email sender (all configured senders, with size cap and content type), send to `ANALYTICS_REPORT_RECIPIENTS`, and upload to Cloud Storage `analytics/reports/YYYY-MM-DD.xlsx` when the bucket is set. Failures are logged, counted and retried on the next tick.
4. **Seed and verify**: `backend/scripts/seed-analytics.sh` generates a realistic week of events and billing activity for local runs; generate the report from it and check every sheet has data and every number matches a SQL query written in the test.
5. **Security review** of all Plan 29 code against plan section 5 and the existing `docs/security-review-2026-10-21.md` format: authz on every route, idempotency, concurrency, webhook auth, rate limits, data minimisation, logging, dependency vulnerabilities. Fix what is found or add tracker rows with severity.
6. **Scalability check**: `EXPLAIN (ANALYZE, BUFFERS)` for the wallet, quote, ledger page, catalog, ingest insert and every aggregation query on seeded data (100k users, 1M events); add indexes where needed; record numbers in the report.
7. **Docs and vault**: update `docs/gap-tracker.md`, the runbook (new env vars, secrets, sweeps, flags, how to switch on plans), `TESTING-NOTES.md` (how to test purchases with sandbox and license testers, which test accounts see hidden plans), and write the vault note `03 - Architecture/Credits, Billing and Analytics.md` if the vault is reachable (otherwise list the text to copy).

## Tests that must exist

- Report from seeded data: every sheet present, totals match SQL, small groups suppressed, no personal data in any cell (scan).
- Idempotent daily run; regeneration CLI overwrites cleanly.
- Email with attachment through the logging sender in tests.

## Finish

All gates from the earlier phases plus `govulncheck`. Write `docs/plans/29-final-report.md`: what was built, how to switch on credits, packs and plans in production step by step, the list from plan section 9, open risks.
