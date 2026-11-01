# Claude Code prompt 30A: deploy blockers and repo hygiene

Read first: `docs/plans/30-review-fixes-photos-sos-reviews.md` (sections 1 and 3.1), `docs/full-review-2026-11-01.md`, `docs/security-review-2026-11-01.md`, `docs/gap-tracker.md` (#95, #100-#105, #116, #117, #121), `TESTING-NOTES.md`, `.gitignore`, `.github/workflows/*`, `backend/cmd/monolith/deploy_manifest_test.go`, `docs/deploy/service.yaml.template`, `docs/deploy/gcp-runbook.md`, `backend/internal/gateway/handlers/cron.go`, `backend/cmd/gateway/main.go`, `backend/internal/grpcapi/ops.go`, `backend/cmd/monolith/main.go`, `backend/migrations/0019_*.up.sql`.

Hard rules: plan section 1. Keep the sign-in test codes and test users exactly as they are.

## Work, in order

1. **#104 commit.** Show `git status` grouped by plan (28, 29, other UI work such as the icon and splash changes). Ask Shashika whether to commit. If yes: remove the stale `.git/index.lock` only if no git process is running, create branch `plan-28-29`, and commit in logical commits (one per phase plus one for unrelated UI work), each message ending with the attribution lines from the session. Do not push.
2. **#100 manifest.** Make CI and deploy work from a clean checkout: generate `backend/service.yaml` from the template in the deploy workflow (`envsubst` with values from repository or environment secrets, never committed), and make the manifest tests run against the template when the generated file is absent. Gate `deploy.yml` on a green CI run for the same commit and a protected `environment:`.
3. **#105 settings.** Add to the template every variable the code requires in production (analytics user-key secret, archive bucket, OTel exporter, Google push service account and audience, store credentials, `CRON_SHARED_SECRET`, `MIN_CREDITS_APP_VERSION`); remove the Cloud SQL annotation and the stale revision; extend the manifest test to fail when a required variable is missing.
4. **#101 migration 0019.** Add a cleanup step before the index (keep the accepted row, mark extra pending rows for the same person and meetup as withdrawn) and a pre-flight query in the runbook. Integration test seeds the duplicate shape and migrates.
5. **#102 tick.** Give the cron route its own write deadline (`http.ResponseController`), per-sweep budgets (analytics sweeps up to 120 s), keep the total under Cloud Scheduler's attempt deadline, and document a second Scheduler job for analytics if the total cannot fit. Test with a slow fake sweep.
6. **#117** final `analytics: flush` sweep that calls the buffer's sync; test that an outbox-delivered event is in the table after a tick.
7. **#116** runbook IAM: `roles/storage.objectUser` on the report prefix, or create-only upload treating 412 as done (choose one, test it).
8. **#95** digest-pin base images, add SBOM (syft) and image scan (trivy) artifacts in CI, keep actions SHA-pinned. S-8: upgrade `golang.org/x/net` to v0.62.0 only if it was published at least two weeks ago; otherwise leave a dated tracker note.
9. **Runbook drift (#121 part):** schema version, Cloud SQL proxy text, sweep count, Scheduler state, minScale and CPU wording, deploy order including migrations 0025-0032.

Finish with the gates in plan section 1 and `docs/plans/30A-completion-report.md`. Do not start 30B.
