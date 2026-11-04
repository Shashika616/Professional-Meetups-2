# 30A completion report: deploy blockers and repo hygiene

Status: **complete** (2026-11-01). Every item has a test that failed before the change. The work is in the working tree on the local branch `plan-28-29`: the five commits from step 1, plus 30A's own changes, which are not committed (plan §1: commits only for step 1). Nothing pushed, deployed, or run against production. The sign-in test codes, test users and the scoped OTP bypass are untouched; the template still carries `TEST_OTP_BYPASS_PHONES` and `_EMAILS`, and the render script warns if either is empty.

## 1. #104: commit

Shashika said yes. The plan said one commit per phase, but files such as `main.go` were changed in several 29 phases, so the commits are by area instead, each of which builds. Branch `plan-28-29` from `main` (f5a5ec3), not pushed:

| Commit | Contents |
|---|---|
| `033f9b8` | App icon colourways, mark SVGs, splash and launch colours (the unrelated UI work) |
| `6775993` | Plan 30 prompts and the 2026-11-01 full review |
| `b0cb4ad` | Plan 29 backend: credits, store purchases, subscriptions, analytics, daily report, OTel, migrations 0025-0032 |
| `7eee467` | Plan 29 app: credits, Premium, purchases, analytics client (1.1.0+7) |
| `3411223` | Plan 29 docs |

There was no stale `.git/index.lock` and no git process running. I scanned the changes for secret patterns before committing and found none; `.env` files and `backend/service.yaml` stay ignored.

## 2. #100: manifest from a clean checkout

- `docs/deploy/service.yaml.template` is the only manifest in git. It uses `${NAME}` placeholders.
- `backend/scripts/render-service-yaml.sh` renders it with `envsubst`:
  - It has a REQUIRED list (refuses to render when one is empty) and an OPTIONAL list (renders, and warns what stays off).
  - A placeholder in neither list is an error.
  - It refuses values containing a quote, backslash, newline or `$`, which would break out of the YAML string.
  - Its first output line is a marker.
- `deploy.yml`:
  - renders the manifest from the `production` environment's secrets;
  - runs the manifest tests on the result;
  - deploys it, then deletes the file. The old `sed` on a committed file is gone.
- The manifest tests check the template always, and `backend/service.yaml` only when it carries the render marker. A clean checkout therefore passes, and a hand-written local file from before (yours, r38) is not mistaken for a deployable one. The two other tests that read the manifest (`otp_bypass_guard_test`, `sender_guard_test`) use the same helper.
- Gates in `deploy.yml`:
  - `environment: production`, a protected environment that waits for an approver;
  - `main` only;
  - a green Backend CI run on the same commit, checked through the Actions API (`actions: read`).

Tests:
- `TestRenderScriptCoversEveryPlaceholder`, `TestServiceTemplateIsRenderedPerRevision`, and the free-tier and silent-failure tests, now over the template.
- I rendered once with dummy values into `backend/service.yaml`, ran all seven manifest tests (all pass), and put your file back. Its checksum is unchanged.

## 3. #105: settings

- **Added:**
  - **Gateway:** `CRON_SHARED_SECRET`, `METRICS_TOKEN` and `OTEL_EXPORTER`.
  - **Monolith:**
    - analytics: `ANALYTICS_USER_KEY_SECRET`, `ANALYTICS_ARCHIVE_BUCKET`, `ANALYTICS_REPORT_RECIPIENTS`;
    - `OTEL_EXPORTER`;
    - app versions: `MIN_CREDITS_APP_VERSION`, `MIN_SUPPORTED_APP_VERSION`;
    - store: `APPLE_APP_STORE_ISSUER_ID`, `_KEY_ID`, `_PRIVATE_KEY`, `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`;
    - Google push: `GOOGLE_PUBSUB_PUSH_AUDIENCE`, `GOOGLE_PUBSUB_PUSH_SERVICE_ACCOUNT`.
  - **Service:** `timeoutSeconds: 600`.
- **Removed:** the Cloud SQL annotation and the fixed `r22` revision and image tags (now `${REVISION}`).
- **Rewritten:** the minScale comment, which still described the reverted "one reserved instance".
- **Test:** `TestServiceManifestDeclaresEveryProductionSetting` parses the manifest with yaml.v3 (already a dependency) and fails, per container, on any missing name. Mutation check: deleting `GOOGLE_PUBSUB_PUSH_SERVICE_ACCOUNT` fails it.

## 4. #101: migration 0019

0019 now runs as one transaction:
1. lock `meetup_requests` against writes;
2. drop the old key, so the cleanup cannot collide with it;
3. mark a `pending` row as `withdrawn` (with `resolved_at` set) where the same person is `accepted` on the same meetup;
4. build the partial unique index.

The test, `internal/platform/db/migration_0019_integration_test.go`, works on its own scratch database:
- **Setup:** it migrates to 0018, then seeds:
  - accepted + pending + an earlier withdrawal for one person;
  - a bystander's pending request;
  - the same person pending on another meetup.
- **Migration:** it migrates to 0019. Before the change, this failed with `23505 could not create unique index`.
- **Checks:**
  - only the duplicate changed;
  - a new second live row is refused;
  - 0019's down migration still refuses, as documented.

Runbook §3a has read-only pre-flight queries for 0019 and 0017. Both run locally (0 rows each).

## 5. #102: the tick

- **Budgets:** each `grpcapi.Sweep` has its own `Budget`: 30 s by default, 120 s for the three heavy analytics sweeps, 10 s for the flush.
- **Deadline:** the monolith keeps 3 s back from the caller's deadline. A sweep is cut at that point, and the ones after it are reported as `skipped: the tick ran out of time` and counted as failures. The report therefore always arrives, and Scheduler retries.
- **Two groups:** `RunScheduledWorkRequest.group` is a new proto field; empty means core, and an unknown group is refused. Two gateway routes:

  | Route | Group | Total | Scheduler attempt deadline |
  |---|---|---|---|
  | `POST /internal/cron/tick` | core, 23 sweeps | 240 s | 300 s |
  | `POST /internal/cron/tick/analytics` | analytics: aggregate, archive and retention, report | 480 s | 540 s |

  Partitions and the flush stay on core, because they are cheap and must never stop.
- **Write deadline:** each route sets its own through `http.ResponseController`, total plus 15 s. The server's 30 s `WriteTimeout` stays for everything else. Cloud Run's request timeout is now 600 s.
- **Why a second job:** the worst case does not fit one tick (23 × 30 s + 3 × 120 s), and the account-deletion purge must never wait behind analytics. Two jobs are within the free tier's three. Commands are in runbook §10.

Tests:
- `ops_test.go`: own budget; answers before the caller's deadline with a wedged slow sweep; runs only the requested group.
- `cron_test.go`: a tick slower than the server's `WriteTimeout` still delivers its report. Mutation: without the deadline call the test fails. Also: each route runs its group within its total, the totals leave room under the attempt deadlines, and the analytics route needs the secret.
- `TestTheAnalyticsSweepBudgetsFitTheAnalyticsTick` reads both sides.

## 6. #117: analytics flush

`analytics: flush` (`Service.SweepFlush`) is the last core sweep. `Buffer.Sync` now returns how many events it wrote; the queue depth reads 0 while events sit in the flusher's batch, which the first version of the test exposed.

Test: `TestTheFlushSweepWritesAnOutboxDeliveredEvent`. A `join_requested` event recorded the way the activity outbox consumer records it is in `analytics.events` after the sweep, with timed flushes set to hourly.

## 7. #116: bucket IAM (chose create-only)

Every report upload is now create-only (`ifGenerationMatch=0`), and a 412 counts as done:
- **The daily run** writes `analytics/reports/YYYY-MM-DD.xlsx` once.
- **A regeneration** is stored beside it as `YYYY-MM-DD.regenerated-<UTC>.xlsx` and recorded as the run's `report_uri`.

The service account keeps only `roles/storage.objectCreator`, and nothing the service runs can replace or delete a stored file. I chose this over granting `objectUser` because it keeps least privilege and keeps an audit trail of regenerations.

Tests:
- the test bucket now refuses overwrites, as `objectCreator` does;
- `TestRegenerationStoresANewObjectAndNeverOverwrites`;
- `TestAStoredButUnrecordedReportUploadCountsAsDone`;
- `TestGCSCreateOnlyUploadTreatsPreconditionFailedAsDone`, which checks the query parameter, that a 412 is done only for a create-only upload, and that a 403 is never done.

Found while doing this: `cmd/analyticsreport --deliver` uploads through the metadata server, so its upload works only on Google Cloud. The runbook said to run it from a laptop. It now says what happens there: the email goes out and the upload fails harmlessly.

## 8. #95 and S-8

- **Images:**
  - both Dockerfiles' base images are pinned by digest (`golang:1.26.10-alpine@sha256:a201…`, `distroless/static-debian12:nonroot@sha256:afa5…`); Dependabot's docker ecosystem keeps them current;
  - CI's Postgres service, gitleaks and the deploy's migrate image are pinned by digest too.
- **CI `docker-build`:** an SBOM (syft v1.54.1, SPDX JSON) and a trivy 0.76.0 scan per image, uploaded as the `image-reports` artifact, kept 90 days. The job fails on a CRITICAL finding that has a fix.
  - **Why images rather than actions:** both tools run as images pinned by digest. A scanner's action tags have been repointed before, and actions stay SHA-pinned anyway.
  - **Tool versions:** both are at least two weeks old (syft 2026-10-06, trivy 2026-10-14).
  - **Local run:** the gateway image's SBOM has 54 packages; trivy finds 0.
- **S-8:** `golang.org/x/net` v0.62.0 was published 2026-10-27 (module proxy), so it is not two weeks old until **2026-11-10**. It stays at v0.60.0; govulncheck says it is not reachable. There is a dated tracker note.

## 9. Runbook drift (#121, runbook part)

- **Status banner:** dated 2026-11-01, last deploy r38.
- **§1:** the scaling row now says minScale 0 with CPU only during requests (and a 600 s timeout); the service-account row; the schema row (repository head 0032; production last recorded at 16, check before deploying); Cloud SQL marked as deleted; `cron-shared-secret` and `metrics-token` in the secrets table.
- **§3:** renders the manifest instead of copying the template by hand. The Cloud SQL proxy text is marked as the Cloud SQL era.
- **New §3a, deploy order:**
  1. check the live schema version;
  2. run the pre-flight queries for 0017 and 0019;
  3. create the secrets, the bucket and the environment values the new manifest needs;
  4. apply 0017-0032 (listed with what each does);
  5. deploy and confirm;
  6. create and enable both Scheduler jobs.
- **§6:** the migrations row (session pooler, no stale version).
- **§10:**
  - the two jobs, with routes, totals and attempt deadlines;
  - "eleven sweeps" and the PAUSED state replaced by commands to check and update the existing job (it was created with a 180 s deadline) and to create the analytics job, with the secret in a header.
- **§11:** CI gate, `production` environment, the render script and its secrets list.
- **§14:** create-only and `objectCreator`, the flush sweep, which job runs what, and regeneration.

## Gates

| Gate | Result |
|---|---|
| `gofmt` | clean |
| `go vet ./...` | clean |
| `golangci-lint run ./...` | 0 issues |
| `gosec -exclude-generated -exclude=G115 ./...` (as CI runs it) | 0. It reported 4 findings in plan 29 code, which would have failed CI's security lint on the branch. All four are false positives (seeded test-data RNG, two Google endpoint URLs, a generated source file's mode) and now carry `#nosec` with the reason, the way CI's comment describes |
| `go test -race -count=1 ./...` | 40 packages, all pass |
| `govulncheck ./...` | no vulnerabilities reached from our code (2 in imported packages and 1 in a required module, none called; S-8) |
| sqlc / buf regenerate | no diff beyond the intended `ops.pb.go` |
| `go mod tidy` | no diff |
| Migrations up, down to 18, up (scratch database) | clean |
| `flutter analyze --fatal-infos` | no issues |
| `dart format --set-exit-if-changed` | 0 changed |
| `flutter test` | 877 pass |
| Workflows parse as YAML | all four |

## Before the next deploy (Shashika only)

1. Push `plan-28-29` and open the pull request, so CI runs once on GitHub. That is the only way to see the new SBOM, scan and secret-scan jobs on the hosted runner.
2. Create the `production` environment (required reviewer, `main` only) and its secrets (runbook §11). Copy `TEST_OTP_BYPASS_PHONES` and `_EMAILS` exactly from the r38 manifest.
3. Create the Secret Manager secrets the manifest now references (runbook §3a step 3), and the analytics bucket with `objectCreator`.
4. Run the pre-flight queries, then deploy through the workflow (runbook §3a).
5. Update `monolith-cron-tick` to a 300 s attempt deadline, and create `monolith-cron-analytics` (runbook §10).
6. On or after 2026-11-10: bump `golang.org/x/net` to v0.62.0 (S-8).

Your local `backend/service.yaml` (r38) is not touched and no longer deploys anything. Keep it only as a record of the r38 values for step 2.
