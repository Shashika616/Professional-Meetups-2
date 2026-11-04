# Deployment guide

How TieHere's backend reaches production, who controls each step, and how to change, undo or recover a release. For first-time setup and the full command reference, see [gcp-runbook.md](gcp-runbook.md).

## How a release works

Every production change follows one path:

1. **Code reaches `main`.** Backend CI and Flutter CI run on the commit.
2. **The owner starts the Deploy workflow** in GitHub Actions and names the revision, such as `r40`. Nothing deploys because a commit landed.
3. **The workflow checks** that it is on `main`, that Backend CI passed on this exact commit, and that the manifest renders with every required value.
4. **It waits for approval** in the `production` environment.
5. **After approval it builds both images, applies migrations, then deploys** the new Cloud Run revision.
6. **It confirms** traffic is on the new revision and `/readyz` answers.

Migrations run before the deploy. The monolith refuses to start on an older schema, so a failed migration leaves the old revision serving.

The app is released separately, through the App Store and Google Play. Keep every backend change compatible with builds already on phones.

## Where things run

| Part | Service | Notes |
|---|---|---|
| API | Cloud Run `meetups-backend`, `asia-south1` | Gateway and monolith in one service; scales to zero |
| Database | Supabase, database `monolith_db` | Service uses the 6543 transaction pooler; migrations and backups use the 5432 session pooler |
| Images | Artifact Registry `meetups-repo` | Old images are cleaned up by policy |
| Scheduled work | Cloud Scheduler | Two jobs call `/internal/cron/*` every 15 minutes |
| Backups | Cloud Storage `meetups-db-backups-740861671089` | Nightly, from GitHub Actions; public access prevented |

## Who can do what

| Identity | Can do | Cannot do |
|---|---|---|
| Owner | Approve deploys, manage settings and secrets | |
| `deployer` service account | Deploy revisions, push to `meetups-repo` | Change who may invoke the service, read secrets |
| Runtime service account | Read the secrets the service uses | Deploy |
| `db-backup` service account | Write backups | Deploy |
| Pull requests and forks | Run CI | Get Google credentials |

GitHub signs in to Google through Workload Identity Federation. No Google key is stored in GitHub, and the identity pool only admits this repository's `main` branch.

## Secrets and settings

| Kind | Where it lives | Examples |
|---|---|---|
| Credentials the service uses | Google Secret Manager | `database-url`, `jwt-private-key`, `twilio-auth-token`, `gmail-app-password` |
| Identifiers for the manifest | GitHub `production` environment secrets | `TWILIO_ACCOUNT_SID`, `GMAIL_ADDRESS`, `ANALYTICS_REPORT_RECIPIENTS` |
| Database URL for migrations and backups | GitHub repository secret `SUPABASE_DIRECT_URL` | Session pooler URL |
| Local development | `backend/.env`, `frontend/.env`, `backend/secrets/` | Git-ignored, never committed |

The repository is public, so `backend/service.yaml` is rendered during the deploy and never committed. Never put a real address, number or key in a tracked file.

**Rotating a secret:** add a new version in Secret Manager, deploy a new revision, confirm `/readyz`, then disable the old version. Rotating the database password also means updating `SUPABASE_DIRECT_URL`.

## Changing the SMS or email provider

**A new provider usually needs code as well as settings.**

| Change | What to update |
|---|---|
| New SMS provider | Sender adapter in the backend, `docs/deploy/service.yaml.template`, `render-service-yaml.sh`, the Deploy workflow's env list, a new Secret Manager secret, new GitHub environment secrets |
| New account, same provider | The GitHub environment secret and the Secret Manager secret only |
| Email to Resend | The backend already supports it; add `RESEND_API_KEY` as a Secret Manager secret and `RESEND_FROM_EMAIL` to the manifest path above |

Afterwards, remove the old secrets and values, and add the provider to the privacy policy's processor list. Keep the OTP test allowlists working (`TESTING-NOTES.md`).

## Deploying

1. Confirm CI is green on `main`.
2. Read any new migration. If it deletes or rewrites data, run its pre-flight from runbook §3a and take a backup.
3. Go to **Actions → Deploy backend → Run workflow**, choose `main`, and enter a new revision name.
4. Review and approve the deployment.
5. Check `/readyz`, the logs, and one real sign-in.

## Undoing a release

**No schema change:** move traffic back, then fix forward.

```bash
gcloud run services update-traffic meetups-backend --region asia-south1 \
  --to-revisions=meetups-backend-rNN=100
```

**With a schema change:** check the old revision can run on the new schema first. A revision is not safe to return to if it reads what a migration removed. Fix forward, or restore a backup, which loses everything written since.

Example: r38 cannot read trusted contacts after migration 0036.

## Backups

The nightly backup runs from `.github/workflows/backup-database.yml`. Check it failing as you would a production incident, since Supabase's free tier has no backup of its own. Take a manual backup before any destructive migration, and rehearse a restore with `backend/scripts/restore-drill.sh`.

## Cost guardrails

- **Cloud Run:** minimum 0 instances, maximum 8, CPU only during requests. Do not change these casually; the manifest tests enforce them.
- **Scheduler:** two jobs, within the three free ones.
- **Artifact Registry:** cleanup policy keeps recent releases and deletes old untagged images.
- **Secret Manager:** small monthly charge beyond 6 active versions.
- **Budget:** `meetups-backend monthly cap` is USD 100. **It only sends alerts at 50%, 90% and 100%. It does not stop spending.**
- **No new infrastructure** (buckets, queues, caches) without a decision recorded in the plan.

## Security controls

| Control | State |
|---|---|
| Deploys need a green CI run on the exact commit | On |
| Deploys need owner approval, from `main` only | On |
| Keyless Google sign-in from GitHub | On |
| Least-privilege deployer account | On |
| Secret scanning and push protection on GitHub | On |
| Gitleaks over the whole history in CI | On |
| Dependabot version and security updates | On |
| Base images and actions pinned to digests | On |
| Image scan and SBOM | On |
| Protection on `main` | **Off, the owner's choice for now** (2026-11-04). The Deploy workflow still checks CI before any deploy |
| Second reviewer | Not possible with one maintainer. Set **Prevent self-review** when a second person joins |
