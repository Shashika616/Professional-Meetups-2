You are working in the Professional-Meetups-Monolith repo. Follow
`docs/plans/20-round8-fixes.md` exactly — it is the plan, this file is just
the handoff. Read that plan in full before writing any code. It covers four
independent fixes; do them in this order, and stop between them to run the
verification steps listed for that fix before moving to the next.

Read `CLAUDE.md` at the repo root first if you haven't already this
session — in particular the Security review rule and the note that
`docs/` is generated (never hand-edit it; only `docs/decisions/`,
`docs/plans/`, `docs/deploy/`, and `docs/gap-tracker.md` inside this repo
are hand-maintained, not the vault-synced `docs/0N-*` folders in the sibling
frontend/backend-split repo — this monolith's own `docs/` layout is
separate from that one, don't confuse the two).

## Fix 1 — Schedule-conflict query (do this first)

1. Write `backend/migrations/0013_schedule_conflict_indexes.up.sql` and
   `.down.sql` exactly as specified in the plan's Fix 1 section (two new
   partial indexes: `idx_meetups_host_live`, `idx_meetup_requests_requester_active`).
2. Rewrite `FindScheduleConflict` in
   `backend/internal/modules/meetup/repository/queries/meetups.sql` per the
   plan's SQL (CTE/UNION rewrite). Do not touch `LockUserSchedule`.
3. Run `sqlc generate` and confirm `meetups.sql.go`/`querier.go` regenerate
   cleanly with no manual edits needed to Go call sites.
4. Run the full existing test suite for this package, especially
   `schedule_conflict_integration_test.go` and
   `schedule_conflict_race_integration_test.go` — both must pass unchanged.
   If either fails, stop and fix the query — do not weaken the test to make
   it pass.
5. Add the new regression test described in the plan (seed other users'
   overlapping live meetups, confirm a clean user gets no false-positive
   conflict).
6. If you have access to `EXPLAIN ANALYZE` against a real Postgres instance
   with the migration applied, run it and report what plan you actually
   see for both UNION branches. If you don't have that access, say so
   explicitly rather than asserting the index is used.

## Fix 2 — ADR-007 + backup automation

1. Write `docs/decisions/adr-007-database-hosting-supabase.md` following
   the exact shape of `adr-001` through `adr-006` (read at least one
   existing ADR in this repo first to match its section headings/tone
   exactly). Use the plan's Context/Decision/Consequences content — don't
   invent numbers not already in `docs/deploy/gcp-runbook.md`.
2. Update the stale connection-pool-sizing comment in
   `docs/deploy/service.yaml.template` per the plan.
3. Write `backend/scripts/backup-database.sh` per the plan's spec (direct
   URL, `pg_dump -Fc`, upload to GCS, delete local copy, non-zero exit on
   any failure).
4. Write `.github/workflows/backup-database.yml` per the plan's spec
   (daily schedule + `workflow_dispatch`, `postgresql-client` install,
   `google-github-actions/auth`, calls the script with secrets).
5. Write `backend/scripts/backup-lifecycle.json` (GCS lifecycle policy,
   age-based delete — pick 30 days unless a value already exists elsewhere
   in this repo's docs that should take precedence).
6. Update `docs/deploy/gcp-runbook.md` §6: replace the "no PITR/backups...
   periodically" line with the real schedule now in place, and add the
   "restore from an automated backup" note pointing at the existing
   restore instructions already in that section.
7. Do NOT attempt to create the GCS bucket, service account, or repo
   secrets yourself — you have no GCP credentials in this environment.
   Leave that as a documented action item (see the plan's exact list) —
   surface it clearly in your completion report, don't silently skip it
   without mentioning it.

## Fix 3 — Premium screen consolidation

1. Read both `frontend/lib/features/premium/premium_page.dart` and
   `frontend/lib/features/premium/premium_plans_page.dart` in full before
   changing either — the plan describes the merge but you need to see the
   exact current code to do it cleanly.
2. Produce exactly one surviving Premium screen: `PremiumPlansPage`'s
   visual design, rebuilt on `PremiumPage`/`PurchaseFlowController`'s real
   data flow. Delete the other file entirely.
3. Add `premiumWeeklyProductId = 'premium_weekly'` and
   `premiumYearlyProductId = 'premium_yearly'` alongside the existing
   `premiumMonthlyProductId`. Fetch all three via one `availableProducts`
   call. Render real `ProductDetails` price/title/description for each —
   zero hardcoded placeholder price strings anywhere in the final code
   (grep for `Rs ` and any literal price string before you finish, and
   confirm none remain).
4. Use one shared perks list across all three tiers (reuse the existing
   four perks verbatim), with a code comment marking this as a deliberate
   placeholder pending a later business decision on per-tier
   differentiation — do not invent different perks per tier.
5. Keep the existing entitled-state/current-plan-badge logic, generalized
   to whichever of the three tiers is active. Keep Restore Purchases
   unchanged.
6. Fix `ProfilePage._premiumRow` (`profile_page.dart:441-444`) to route to
   the one surviving screen unconditionally, regardless of entitlement
   state.
7. Update or replace any test currently exercising either old screen
   (including `page_background_test.dart`) to point at the surviving
   screen, and add coverage for the three-product fetch (all present; one
   or two missing; none available).
8. Grep the whole `frontend/` tree for the deleted class/file name and
   confirm zero remaining references (including doc comments).
9. The new product IDs must be created in App Store Connect and Google
   Play Console for real purchases to work — you cannot do this yourself.
   Surface it clearly as an action item in your completion report.

## Fix 4 — Cosmetic fixes

Do all four, each is small and independent:

1. `backend/internal/modules/meetup/traits.go:91-95` — fix the stale
   inline comment to match the file's own (correct) header statement that
   traits are private, shown only to the rater. Comment-only, no logic
   change.
2. `frontend/lib/features/premium/premium_plans_page.dart:167` — if this
   file still exists after Fix 3's rewrite, replace the hardcoded
   `Color(0xFF148F52)` with `AppPalette.brandGreen`. If Fix 3 already
   deleted/replaced this file, just confirm the surviving code never
   reintroduces a hardcoded green and note that in your report.
3. `frontend/lib/features/auth/social_sign_in_section.dart:144` — read the
   surrounding `SigningInOverlay` wiring first, then make the per-button
   spinner and the full-page overlay mutually exclusive (only one loading
   indicator visible at a time), per the plan's description.
4. `frontend/lib/features/meetups/widgets/map_location_step.dart:15-17` —
   update the doc comment to describe the current default (OpenStreetMap
   via Photon/Nominatim on Android, Stadia only as an explicit opt-in
   build flag per `TESTING-NOTES.md`) instead of the stale "still
   provisional" framing. Comment-only, no logic change.

## Before you report done

Run through the plan's full "Verification checklist" section yourself —
don't just claim each fix works, actually run `go build ./...`, `go vet
./...`, `go test ./...`, `flutter analyze`, and `flutter test`, and paste
their real output (or a clear summary of pass/fail counts) in your
completion report. Then update `docs/gap-tracker.md`'s Round 8 section:
mark items #42, #43, #44, #47, #48, #49, #50 `DONE (2026-09-18)` with a
one-line note on what changed for each, matching this file's existing
convention exactly (look at how earlier rounds' items were marked done
before writing these).

Your completion report must explicitly list, separately from the code
changes: (a) the two GCP/store action items that need Shashika's own
manual setup and cannot be verified by tests, (b) the exact test commands
you ran and their pass/fail results, (c) confirmation (via grep, not
assertion) that no hardcoded premium price strings and no references to
the deleted Premium screen file remain anywhere in `frontend/`.
