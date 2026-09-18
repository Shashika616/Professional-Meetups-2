# Plan 20 — Round 8 fixes: schedule-conflict query, Supabase ADR + backup, Premium consolidation, cosmetics

Fixes gap-tracker items #42, #43, #47, #44, #48, #49, #50 from `docs/gap-tracker.md`'s
Round 8 section. Four independent pieces of work, safe to build in any order
(no shared files between Fix 1/2/3, cosmetics touch four unrelated files) —
sequenced below by size, not dependency.

---

## Fix 1 — Schedule-conflict query no longer scans the whole platform (gap #42)

### The problem, precisely

`FindScheduleConflict` (`backend/internal/modules/meetup/repository/queries/meetups.sql:512-555`)
filters live meetups by time-overlap first, then narrows to the caller with
`AND (m.host_user_id = :user_id OR r.id IS NOT NULL)`, where `r.id` comes
from a `LEFT JOIN meetup_requests r ON r.meetup_id = m.id AND
r.requester_id = :user_id ...`. Because the user-scoping condition is OR'd
*across* a joined relation, Postgres cannot seek an index on "this user's
meetups" — the natural plan is a range scan over every currently
`open`/`full`, not-yet-ended meetup on the platform, filtered down to the
caller afterward. This runs inside the `pg_advisory_xact_lock` transaction
on every `CreateMeetup`/`RequestToJoin`, and the unlocked `GET
/v1/meetups/schedule-check` preview endpoint (`schedule_conflict.go`,
called from the scheduling UI on every date/time-step edit) runs the
identical shape at even higher call volume. Cheap today; degrades with
total platform meetup count, not per-user load — exactly the kind of thing
to fix while it's cheap to fix, not after it's paged someone.

### The fix

Split into two independently-indexable branches — "meetups I host" and
"meetups I've requested" — combined with `UNION`, joined back to the full
row shape once, instead of one query with an OR-across-join. A meetup's
host and requester are always different people (self-requests are rejected
elsewhere), so there's no dedup concern.

**New migration** `backend/migrations/0013_schedule_conflict_indexes.up.sql`
(+ matching `.down.sql`):

```sql
-- Lets FindScheduleConflict's "meetups I host" branch seek directly to one
-- user's live meetups instead of scanning every live meetup on the
-- platform. Partial + covers the exact predicate shape that branch uses.
CREATE INDEX idx_meetups_host_live ON meetup.meetups (host_user_id, window_start, window_end)
    WHERE status IN ('open', 'full');

-- Same idea for the "meetups I've requested" branch: narrows
-- meetup_requests to one user's still-live requests before the join to
-- meetups, instead of the plain idx_meetup_requests_requester(requester_id)
-- index needing a post-filter on status for every row it returns.
CREATE INDEX idx_meetup_requests_requester_active ON meetup.meetup_requests (requester_id)
    WHERE status IN ('pending', 'accepted');
```

Down migration drops both, in reverse order.

**Rewrite `FindScheduleConflict`** in
`backend/internal/modules/meetup/repository/queries/meetups.sql` (replacing
lines 512-555 — keep every existing comment's substance, they're accurate
and hard-won, just adapt them to the new shape):

```sql
-- name: FindScheduleConflict :one
-- The one-meetup-at-a-time rule (2026-09-15): the earliest live meetup the
-- user is already committed to that overlaps [window_start, window_end).
-- "Committed" is hosting it, or holding a pending or accepted request on
-- it — a pending request counts because accepting it later must never be
-- what creates a double booking. "Live" is open/full and not yet over, so
-- a finished or cancelled meetup never blocks anything. exclude_id keeps a
-- join attempt from colliding with the very meetup being joined (a repeat
-- request on the same meetup is the requests table's own conflict, with
-- its own message). Half-open overlap, so back-to-back windows are fine.
--
-- Rewritten 2026-09-18 (gap #42) from a single OR-across-a-join query,
-- which could not use an index for the caller-scoping condition and scanned
-- every live meetup on the platform. Split into two independently indexed
-- branches (idx_meetups_host_live, idx_meetup_requests_requester_active)
-- combined with UNION, each returning only the caller's own candidate
-- meetup ids before the full row shape is ever assembled.
WITH hosting AS (
  SELECT m.id
  FROM meetup.meetups m
  WHERE m.host_user_id = sqlc.arg(user_id)
    AND m.status IN ('open', 'full')
    AND m.window_end > now()
    AND m.window_start < sqlc.arg(window_end)
    AND m.window_end > sqlc.arg(window_start)
    AND m.id <> sqlc.arg(exclude_id)
), requested AS (
  SELECT m.id
  FROM meetup.meetup_requests r
  JOIN meetup.meetups m ON m.id = r.meetup_id
  WHERE r.requester_id = sqlc.arg(user_id)
    AND r.status IN ('pending', 'accepted')
    AND m.status IN ('open', 'full')
    AND m.window_end > now()
    AND m.window_start < sqlc.arg(window_end)
    AND m.window_end > sqlc.arg(window_start)
    AND m.id <> sqlc.arg(exclude_id)
), candidate_ids AS (
  SELECT id FROM hosting
  UNION
  SELECT id FROM requested
)
SELECT
  m.*,
  COALESCE(u.full_name, '') AS host_full_name,
  u.profile_photo_url AS host_profile_photo_url,
  COALESCE(u.trust_level, 0) AS host_trust_level,
  COALESCE(ratings.rating_average, 0)::numeric(3,2) AS host_rating_average,
  COALESCE(ratings.rating_count, 0)::int AS host_rating_count,
  (SELECT count(*) FROM meetup.meetup_requests r2 WHERE r2.meetup_id = m.id AND r2.status = 'accepted') AS accepted_count,
  r.status AS my_request_status,
  r.id AS my_request_id
FROM candidate_ids c
JOIN meetup.meetups m ON m.id = c.id
LEFT JOIN meetup.user_display_cache u ON u.user_id = m.host_user_id
LEFT JOIN LATERAL (
  SELECT ROUND(AVG(score), 2) AS rating_average, count(*) AS rating_count
  FROM meetup.meetup_user_ratings mr WHERE mr.rated_user_id = m.host_user_id
) ratings ON true
LEFT JOIN meetup.meetup_requests r
  ON r.meetup_id = m.id
 AND r.requester_id = sqlc.arg(user_id)
 AND r.status IN ('pending', 'accepted')
-- LIVE, defined here, in the service's ListActiveMeetups isLive closure,
-- and (as BROWSABLE, 'open' only) in ListOpenMeetupsFirstPage/AfterCursor
-- above. Keep the three in step.
ORDER BY m.window_start ASC, m.id ASC
LIMIT 1;
```

Do not touch `LockUserSchedule` — that query is an unrelated advisory-lock
statement, not part of this scan.

**Regenerate sqlc** (`sqlc generate`, same as every prior query change in
this repo) so `meetups.sql.go`/`querier.go` pick up the rewritten query. The
Go call sites (`schedule_conflict.go`, `meetups_postgres.go`) call this
query by generated function name and do not need to change — same
parameters, same return shape, same semantics, just a different plan
underneath.

**Verify, don't just assert**: run the existing
`schedule_conflict_integration_test.go` and
`schedule_conflict_race_integration_test.go` unchanged — they test
*behavior* (conflict detected/not detected, exactly one wins under
concurrency), which must be identical before and after this rewrite. If
either fails, the rewrite changed semantics, not just the plan — stop and
fix before proceeding, don't loosen the test.

**Add one new test** in `schedule_conflict_integration_test.go` that seeds
several *other users'* overlapping live meetups (hosted and requested) at
volume, then confirms `FindScheduleConflict` for a *different* user with no
conflicts of their own returns none — this is the regression guard for the
specific bug being fixed (a platform-wide scan finding a false positive
from someone else's meetup would be the failure mode to catch).

**If a Postgres instance with real `EXPLAIN ANALYZE` access is available in
your environment**, run `EXPLAIN ANALYZE` on the rewritten query against
the dev/test database with a realistic-ish row count and confirm both
branches show an index scan on the new indexes, not a sequential scan —
report what you see either way, don't guess.

---

## Fix 2 — ADR-007 (Supabase migration, retroactive) + automated backup (gap #43)

### Part A: the ADR

The 2026-09-15 Cloud SQL → Supabase database migration already happened and
is documented operationally in `docs/deploy/gcp-runbook.md`, but — per this
repo's own convention of recording architecture-significant decisions —
has no ADR. Write `docs/decisions/adr-007-database-hosting-supabase.md`,
following this repo's existing ADR shape (see `adr-001` through `adr-006`
for the format: Status, Context, Decision, Consequences, Related).

**Context** (cite the actual numbers already in the runbook, don't
re-derive them): Cloud SQL (`db-g1-small` + 10 GB SSD + PITR) was the one
meaningful recurring charge in the GCP deployment, on the order of
US$25-35/month (`docs/deploy/gcp-runbook.md` §5) — for a pre-revenue,
pre-launch app, this is a real ongoing cost with no offsetting revenue yet.
Supabase's free tier provides a managed Postgres 17 instance (with PostGIS
and pgcrypto, both required by this schema) at zero monthly cost, in the
same region (Mumbai/`ap-south-1`) as the existing Cloud Run deployment, so
no added cross-region latency.

**Decision**: move the database to Supabase; keep Cloud Run as the compute
layer (Cloud Run itself was never the cost driver, no reason to move it).
Record the concrete facts already established operationally: dedicated
`monolith_db` database (not `postgres`, to avoid a schema-name collision
with Supabase's own `auth` schema); connect via the transaction pooler for
the app (`cache_describe` query-exec mode required for pgx compatibility
with transaction-mode pooling — the app has no session-level SQL, so this
is safe) and via the direct IPv6 connection for migrations/admin work.

**Consequences** — list all of these, they're real trade-offs, not just
upside:
- Zero ongoing database cost, vs. ~US$25-35/month previously.
- **No managed backups/PITR on the free tier** — this is what Fix 2 Part B
  below exists to address; call it out here as the direct cost of this
  decision, not a separately-discovered surprise.
- **The free-tier project auto-pauses after 7 days of inactivity** (per the
  runbook) — a real operational risk if traffic is ever low enough to hit
  this pre-launch; note that Cloud Run's own request traffic is what would
  need to be relied on to keep it awake, and that this is worth revisiting
  if the project is ever left idle for a stretch (e.g. between review
  rounds).
- Connection ceiling is real but has headroom today: `db.MaxConns=20` ×
  Cloud Run `maxScale:8` = up to 160 concurrent connections against
  Supabase's ~200 client-connection limit on the pooler — thinner margin
  than Cloud SQL had, worth revisiting before either `maxScale` or the
  per-instance pool size is increased.
- A future paid Supabase tier (or moving back to a managed Postgres with
  backups) is the natural next step once real revenue exists to justify it
  — this ADR is explicitly a pre-revenue-stage trade-off, not a permanent
  architectural stance.

**Also fix** `docs/deploy/service.yaml.template`'s guardrail comment near
the connection-pool sizing, which still describes the Cloud-SQL-era
connection math — update it to reference Supabase's pooler limits instead
(the §6 table's numbers above), so a future reader isn't sizing against the
wrong backend's ceiling.

### Part B: automated backup

Replace the runbook's "no PITR/backups on free (take `pg_dump` via the
direct URL periodically)" with an actual scheduled job. Optimize for
near-zero added cost, consistent with the reason this migration happened at
all.

**New script** `backend/scripts/backup-database.sh`:
- Takes the Supabase **direct** connection URL (not the pooler URL — pooled
  connections aren't meant for a long-running `pg_dump`) from an env var,
  e.g. `SUPABASE_DIRECT_URL`.
- Runs `pg_dump "$SUPABASE_DIRECT_URL" -Fc -f "backup-$(date -u +%Y%m%dT%H%M%SZ).dump"`
  (custom format — smaller, and what the runbook's own restore notes at the
  bottom of §6 already assume).
- Uploads the resulting file to a GCS bucket via `gsutil cp` (bucket name
  from an env var, e.g. `BACKUP_GCS_BUCKET`), then deletes the local copy.
- Exits non-zero on any failure of the dump or the upload — this must be a
  loud failure, not a silently-skipped step, given what's at stake.

**New workflow** `.github/workflows/backup-database.yml`:
- Triggers: daily `schedule` (pick a time, e.g. `0 18 * * *` — well outside
  the meetup-lifecycle poller's own 60-second cadence, no interaction
  between the two) plus `workflow_dispatch` for an on-demand manual run.
- Steps: checkout, install the `postgresql-client` package (for `pg_dump`
  matching the Supabase Postgres 17 server version — confirm the client
  version needed, Postgres major-version mismatches between `pg_dump` and
  server can fail), authenticate to GCP via `google-github-actions/auth`
  using a service-account key stored as a repo secret, run
  `backup-database.sh` with `SUPABASE_DIRECT_URL` and `BACKUP_GCS_BUCKET`
  from repo secrets.
- On failure, the workflow's own failure state is the alert (GitHub
  surfaces a failed scheduled run) — no additional notification wiring
  needed for this round.

**New file** `backend/scripts/backup-lifecycle.json` — a GCS bucket
lifecycle-policy document (age-based delete after, e.g., 30 days) for
Shashika to apply once via `gsutil lifecycle set backup-lifecycle.json
gs://<bucket>` after creating the bucket — write the JSON, but do not
attempt to apply it yourself (no GCP credentials in your environment to do
so, and this needs Shashika's own `gcloud`/`gsutil` session).

**Update `docs/deploy/gcp-runbook.md` §6**: replace the "no PITR/backups"
caveat line with the actual schedule now in place, and add a short "Restore
from an automated backup" note pointing at the existing restore-from-dump
instructions at the bottom of that section (they already cover the
`search_path`/`known_companies` gotchas — just note that an automated
backup restores the same way as the manual ones already described there).

**New gap-tracker entry needed** (add to `docs/gap-tracker.md`'s Round 8
section once built): mark #43 `DONE`, and add a "needs Shashika's action"
note listing exactly what has to happen outside this codebase before the
workflow can run for real: (1) create a GCS bucket in the existing GCP
project, scoped to backups only; (2) create a service account with
`storage.objectAdmin` on *that bucket only* (not project-wide — least
privilege, this account's only job is writing backup files); (3) generate
and add that service account's JSON key as repo secret
`GCP_BACKUP_SA_KEY`; (4) add `SUPABASE_DIRECT_URL` and `BACKUP_GCS_BUCKET`
as repo secrets; (5) apply `backup-lifecycle.json` via `gsutil lifecycle
set`. None of this blocks the workflow/script code from being written and
reviewed now — same pattern as every other vendor-credential dependency in
this repo's history (Twilio, Resend, Firebase all shipped code before
credentials existed).

---

## Fix 3 — One real Premium screen, three tiers (gap #47, #48)

### The problem

Two Premium screens exist. `frontend/lib/features/premium/premium_page.dart`
(`PremiumPage`) is the real one — wired to `PurchaseFlowController` and
`SubscriptionService`, fetches real `ProductDetails`, handles the
entitled/restore/error states correctly, but sells exactly one product
(`premium_monthly`) and has plainer UI. `premium_plans_page.dart`
(`PremiumPlansPage`) has the better visual design (a featured plan card,
perks in a white inset, a billing-choice row) but is entirely fake — every
price is the literal string `Rs xxxx`, and the call-to-action button just
shows a toast. `ProfilePage._premiumRow` (`profile_page.dart:441-444`)
sends every tap to the fake one, `PremiumPlansPage`, regardless of whether
the user is already an entitled subscriber.

### The fix

Produce **exactly one** Premium screen when you're done — delete the other
file entirely (whichever you don't keep the shape of), and remove every
now-stale reference to it (including its own doc comments claiming to be
"reached from ProfilePage" if that file goes away, and the
`page_background_test.dart` reference to whichever class name is retired).
Keep `PremiumPlansPage`'s visual design as the base (it's the better one),
rebuilt on `PremiumPage`/`PurchaseFlowController`'s real data flow. Exact
class/file naming is your call — the requirements below are about
behavior, not naming.

**Three tiers, not two**: define three product ID constants analogous to
the existing `premiumMonthlyProductId`:

```dart
const String premiumWeeklyProductId = 'premium_weekly';
const String premiumMonthlyProductId = 'premium_monthly'; // unchanged, already deployed as a concept
const String premiumYearlyProductId = 'premium_yearly';
```

Fetch all three via one `availableProducts([premiumWeeklyProductId,
premiumMonthlyProductId, premiumYearlyProductId])` call, exactly like the
existing single-product call does today, and render each tier's real
`ProductDetails.price`/`.title`/`.description` — **no hardcoded `Rs xxxx`
or any other placeholder price string anywhere in the final code.** If the
store hasn't been configured with all three product IDs yet (a real
possibility until Shashika sets them up in App Store Connect / Play
Console — flag this as a needs-Shashika's-action item, same category as
the App Store Connect API key), the screen should degrade the same way the
existing `PremiumPage` already does when `_products` comes back
empty/partial: show what's actually available, not an error for the whole
screen over one missing product.

**Perks are shared and explicitly placeholder for now** — Shashika will
decide real per-tier differentiation later as a business decision, not a
design one. Use one shared perks list across all three tiers (reuse
`PremiumPlansPage`'s existing four perks verbatim: hosting cap, Happening
Soon filters, a Premium profile mark, priority support) rather than
inventing different perks per tier. Leave a clear code comment marking this
as a deliberate placeholder pending a real product decision, same spirit as
the existing `_pricePlaceholder` comment you're replacing.

**Tier presentation**: show all three as selectable options (weekly,
monthly, yearly), each with its real price from `ProductDetails`. Mark one
tier as the visually featured/recommended option — Yearly is the
reasonable default choice (longest commitment, matches the existing
featured-card treatment's "two months free" framing already written for an
annual plan) — but this is a presentation choice, adjust it if a clearly
better option falls out of implementation. Buying any tier goes through the
same `PurchaseFlowController.buy(product)` call already built; do not
special-case a tier in the purchase logic itself.

**Entitled state**: reuse the existing `_statusCard`/`entitled` logic from
`PremiumPage` — show current plan status at the top, and disable/relabel
("CURRENT PLAN") the tier that matches an active subscription, exactly as
today's single-tier version already does. `ProfilePage._premiumRow` should
navigate to this one real screen unconditionally (entitled or not) — the
screen itself is what has to correctly render both states, not the caller
routing around it.

**Restore Purchases** stays, unchanged in behavior.

**Tests**: update or replace whatever currently exercises `PremiumPage`
and/or `PremiumPlansPage` (including `page_background_test.dart`) to point
at the one surviving screen. Add coverage for the three-product fetch (all
three returned; one or two missing; none available) mirroring the existing
single-product test's shape if one exists.

---

## Fix 4 — Cosmetic fixes (gaps #44, #49, #50)

Four small, independent, no-behavior-change fixes:

1. **`backend/internal/modules/meetup/traits.go:91-95`** — `validateTraits`'s
   inline comment says traits "end up displayed on someone else's
   profile." This is stale; the file's own header (correct) says traits
   are private, shown only back to the rater, never aggregated or shown on
   anyone's profile. Fix the inline comment to match the header — no code
   change, this is a comment-only fix.

2. **`frontend/lib/features/premium/premium_plans_page.dart:167`** —
   `const green = Color(0xFF148F52)` should be `AppPalette.brandGreen`
   (`0xFF34C24C`), matching every other use of green on the same screen
   (lines 139, 370, 382, 393 already do this correctly). One-line fix — if
   this file is being rewritten as part of Fix 3 anyway, just make sure the
   surviving code never reintroduces this hardcoded value.

3. **`frontend/lib/features/auth/social_sign_in_section.dart:144`** — the
   tapped provider button's own `PrimaryButton(isLoading: isRunning)`
   spinner stays visible underneath `SigningInOverlay`'s full-page ring,
   defeating the overlay's own stated purpose (its doc comment says it
   exists specifically so two loading indicators never show at once). Fix:
   once `SigningInOverlay` is shown (i.e. once the overlay's own busy state
   is true), the per-button spinner should not also render — pass `false`
   for that button's `isLoading` while the overlay owns the loading state,
   or equivalent; look at how `onBusyChanged`/the overlay's visibility is
   wired today and make the two mutually exclusive rather than layered.

4. **`frontend/lib/features/meetups/widgets/map_location_step.dart:15-17`**
   — the doc comment still describes the Android branch as "the existing
   Stadia Maps implementation, still provisional." Android now defaults to
   OpenStreetMap (Photon/Nominatim), with Stadia kept only as an explicit,
   documented opt-in build flag (see `TESTING-NOTES.md`). Update the
   comment to describe the current default accurately — no code change.

---

## Verification checklist before reporting done

- [ ] `go build ./...` and `go vet ./...` clean.
- [ ] `flutter analyze` clean.
- [ ] `go test ./...` — specifically confirm
      `schedule_conflict_integration_test.go` and
      `schedule_conflict_race_integration_test.go` both still pass
      unchanged, plus the new platform-wide-scan regression test from Fix 1.
- [ ] `flutter test` — specifically confirm whatever replaces
      `page_background_test.dart`'s Premium-page coverage passes.
- [ ] Repo-wide grep confirms only one Premium screen class/file remains,
      and zero remaining references to whichever one was retired.
- [ ] Repo-wide grep confirms `Rs xxxx` (or any other hardcoded premium
      price string) no longer appears anywhere in `frontend/`.
- [ ] `docs/decisions/adr-007-database-hosting-supabase.md` exists and
      reads clean against the actual runbook numbers.
- [ ] `docs/deploy/gcp-runbook.md` §6 no longer says backups are taken
      "periodically" by hand.
- [ ] Update `docs/gap-tracker.md`'s Round 8 section: mark #42, #43, #44,
      #47, #48, #49, #50 `DONE (date)` with a one-line note on what
      changed, matching this file's existing convention — don't leave them
      silently fixed with no tracker update.

## Related

`docs/gap-tracker.md` Round 8 · `docs/decisions/adr-005-one-meetup-at-a-time.md`
· `docs/decisions/adr-031...` (billing, in the vault, ported concept) ·
`docs/deploy/gcp-runbook.md`
