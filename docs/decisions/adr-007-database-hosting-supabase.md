# ADR-007 - Database Hosting Moves from Cloud SQL to Supabase

## Status

Accepted (2026-09-15; recorded retroactively 2026-09-18, gap #43).

## Context

The backend ran on Cloud Run with a Cloud SQL Postgres instance
(`db-g1-small`, 10 GB SSD, point-in-time recovery). Cloud Run itself sat
inside the always-free allowance at this traffic, so Cloud SQL was the one
meaningful recurring charge in the deployment: on the order of US$25-35 a
month in `asia-south1` (`docs/deploy/gcp-runbook.md` §5). For a pre-revenue,
pre-launch app that is a real ongoing cost with nothing offsetting it yet.

Supabase's free tier provides a managed Postgres 17 instance with the two
extensions this schema needs (PostGIS for the meetup geography column and
its distance queries, pgcrypto) at zero monthly cost, and offers a Mumbai
region (`ap-south-1`), the same city as the existing Cloud Run deployment,
so the move adds no cross-region latency. (A first attempt in Tokyo cost
about 70 ms per round trip and was deleted the same day; the runbook
records it.)

The original Cloud SQL choice was made when the deployment was being
brought up on Google Cloud end to end. This is a change of hosting provider
for the database, not a refinement of that choice, so it gets its own ADR
rather than an addendum.

## Decision

Move the database to Supabase's free tier. Keep Cloud Run as the compute
layer: it was never the cost driver, and nothing about it needed to change
beyond the connection string.

The concrete arrangement, as already established operationally in the
runbook (§6):

- A dedicated database `monolith_db` inside the Supabase project, not the
  default `postgres` database. Supabase keeps its own `auth` schema in
  `postgres`, which collides with this app's `auth` schema.
- The app connects through the transaction pooler (Supavisor, port 6543)
  with pgx's `default_query_exec_mode=cache_describe`. Transaction-mode
  pooling hands a different server connection to each transaction, so
  anything that relies on session state (prepared statements by name,
  session variables, advisory locks that outlive a transaction) would
  break. The app has none of that: `cache_describe` avoids named prepared
  statements, and the one advisory lock it takes
  (`pg_advisory_xact_lock`, ADR-005) is transaction-scoped and is taken,
  used and released inside a single `pgx.Tx`, that is, on one borrowed
  connection.
- Migrations and admin work use the direct connection (port 5432, IPv6
  only on the free tier). Long-running or session-dependent work, including
  `pg_dump`, goes through this URL, never the pooler.

## Consequences

- Zero ongoing database cost, against roughly US$25-35 a month before.
- **No managed backups and no point-in-time recovery on the free tier.**
  This is the direct price of the decision, not a separate discovery.
  Plan 20 Fix 2 adds a scheduled `pg_dump` to Google Cloud Storage
  (`backend/scripts/backup-database.sh`, `.github/workflows/backup-database.yml`)
  with a 30-day retention policy; a restore is a manual `pg_restore` per
  the runbook's restore notes. Recovery is therefore to the last nightly
  dump, not to a point in time.
- **The free-tier project pauses after 7 idle days.** Cloud Run's own
  request traffic is what keeps it awake; if the app is left without
  traffic for a week, say between review rounds before launch, the first
  request afterwards fails until the project is unpaused in the Supabase
  dashboard. Worth revisiting if the project is going to sit idle.
- The connection ceiling is real but has headroom today: `db.MaxConns=20`
  per Cloud Run instance times `maxScale: 8` is up to 160 client
  connections against the pooler's limit of 200 (the pooler multiplexes
  those onto about 15 server connections). That is a thinner margin than
  Cloud SQL's `max_connections` gave; raise `maxScale` or the per-instance
  pool only after re-doing this arithmetic. `service.yaml.template`'s
  guardrail comment now states it against the pooler, not Cloud SQL.
- A paid Supabase tier (which brings daily backups and PITR) or a return to
  a managed Postgres with backups is the natural next step once revenue
  justifies it. This is a pre-revenue trade-off, recorded as such, not a
  permanent stance on where the database lives.

## Related

`docs/deploy/gcp-runbook.md` §5 (Cloud SQL cost as observed) and §6 (the
Supabase arrangement, connection strings, restore notes) ·
`docs/plans/20-round8-fixes.md` Fix 2 (this ADR and the backup job) ·
`docs/decisions/adr-005-one-meetup-at-a-time.md` (the transaction-scoped
advisory lock that transaction pooling has to be compatible with) ·
`docs/deploy/service.yaml.template` (`maxScale` guardrail) ·
`backend/scripts/backup-database.sh` · `.github/workflows/backup-database.yml`
