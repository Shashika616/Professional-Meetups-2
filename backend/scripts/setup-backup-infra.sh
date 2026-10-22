#!/usr/bin/env bash
# One-time cloud setup for the nightly backup and the scheduled sweeps.
#
# Run this once, from a shell logged in as a project owner:
#
#     gcloud auth login
#     backend/scripts/setup-backup-infra.sh
#
# It is idempotent: every step checks for what it creates first, so running
# it again after a partial failure is safe and is the intended way to finish.
#
# WHAT IT CREATES, AND WHY EACH PIECE IS FREE
#
#   1. A GCS bucket for the dumps, in us-central1. The region is NOT
#      arbitrary: Cloud Storage's always-free 5 GB only applies in
#      us-east1, us-west1 and us-central1. A bucket in asia-south1 next to
#      the service would be billed from the first byte. A 30-day lifecycle
#      rule keeps it far under 5 GB.
#
#   2. A service account that can write to that bucket and nothing else.
#      IAM is free.
#
#   3. Workload Identity Federation, so GitHub Actions authenticates with a
#      short-lived token instead of a JSON key. Free. This replaces the
#      GCP_BACKUP_SA_KEY secret, which was never set — which is why all 27
#      backup runs between 2026-09-25 and 2026-10-22 failed at the auth
#      step, and why there was no backup when the database was lost.
#
#   4. A Cloud Scheduler job that calls the service's /internal/cron/tick,
#      which is what runs the periodic sweeps now that the service scales to
#      zero. Cloud Scheduler's free tier is 3 jobs; this is the first.
#
#   5. A Secret Manager secret holding the shared secret that route checks.
#
# THE ONE THING THIS SCRIPT CANNOT DO: set the GitHub Actions secret
# SUPABASE_DIRECT_URL. It prints what to do at the end.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-project-285b9289-549d-4fef-92c}"
PROJECT_NUMBER="${PROJECT_NUMBER:-740861671089}"
REPO="${REPO:-Shashika616/Professional-Meetups-2}"
REGION="${REGION:-asia-south1}"          # where the Cloud Run service lives
BUCKET_LOCATION="${BUCKET_LOCATION:-asia-south1}"  # co-located with the DB and Cloud Run
BUCKET="${BUCKET:-tiehere-db-backups-${PROJECT_NUMBER}}"
SA_NAME="db-backup"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
POOL="github"
PROVIDER="github"
SERVICE="${SERVICE:-meetups-backend}"
CRON_SECRET_NAME="cron-shared-secret"
CRON_JOB="monolith-cron-tick"
# Every 15 minutes. See the note on cadence at the bottom of this file.
CRON_SCHEDULE="${CRON_SCHEDULE:-*/15 * * * *}"

say() { printf '\n=== %s\n' "$*"; }

gcloud config set project "$PROJECT_ID" >/dev/null

say "Enabling the APIs this needs"
# storage is already on; the rest are for federation and the scheduler.
gcloud services enable \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  storage.googleapis.com \
  secretmanager.googleapis.com \
  cloudscheduler.googleapis.com

say "Bucket gs://${BUCKET} in ${BUCKET_LOCATION}"
if gcloud storage buckets describe "gs://${BUCKET}" >/dev/null 2>&1; then
  echo "already exists"
else
  # Uniform access: per-object ACLs are a way to make a backup bucket
  # readable by accident, and nothing here needs them.
  gcloud storage buckets create "gs://${BUCKET}" \
    --location="$BUCKET_LOCATION" \
    --default-storage-class=STANDARD \
    --uniform-bucket-level-access \
    --public-access-prevention
fi

say "Applying the 30-day retention lifecycle"
gcloud storage buckets update "gs://${BUCKET}" \
  --lifecycle-file="$(dirname "$0")/backup-lifecycle.json"

say "Artifact Registry cleanup policy"
# Artifact Registry's free tier is 0.5 GB. meetups-repo was at 286 MB on
# 2026-10-22 across ~34 revisions and grows with every push, so without a
# policy it crosses the free limit within a few more deploys. Keep the most
# recent 5 versions of each image and delete untagged ones after a week —
# rollback targets stay, build debris does not.
policy_file="${workdir_policy:-$(mktemp)}"
cat > "$policy_file" <<'POLICY'
[
  {
    "name": "keep-recent-releases",
    "action": { "type": "Keep" },
    "mostRecentVersions": { "keepCount": 5 }
  },
  {
    "name": "delete-untagged",
    "action": { "type": "Delete" },
    "condition": { "tagState": "untagged", "olderThan": "7d" }
  }
]
POLICY
gcloud artifacts repositories set-cleanup-policies meetups-repo \
  --location="$REGION" --policy="$policy_file" >/dev/null
rm -f "$policy_file"
echo "applied: keep 5 most recent, delete untagged after 7d"

say "Service account ${SA_EMAIL}"
if gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
  echo "already exists"
else
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="Nightly database backup" \
    --description="Writes pg_dump output to gs://${BUCKET}. No other access."
fi

say "Granting it object access on that bucket ONLY"
# Scoped to the bucket, not the project: a credential that can write backups
# should not also be able to read every other bucket that ever gets created.
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin" >/dev/null

say "Workload identity pool '${POOL}'"
if gcloud iam workload-identity-pools describe "$POOL" --location=global >/dev/null 2>&1; then
  echo "already exists"
else
  gcloud iam workload-identity-pools create "$POOL" \
    --location=global \
    --display-name="GitHub Actions"
fi

say "Workload identity provider '${PROVIDER}'"
# THE ATTRIBUTE CONDITION IS THE SECURITY BOUNDARY. Without it, any GitHub
# repository on the internet could mint a token this project accepts.
#
# It pins two claims:
#   repository — this repo, which is public, so the restriction matters.
#   ref        — refs/heads/main. A pull request from a fork runs with
#                ref=refs/pull/N/merge, so a PR that edits the workflow
#                cannot use this provider.
ATTR_CONDITION="assertion.repository == '${REPO}' && assertion.ref == 'refs/heads/main'"
if gcloud iam workload-identity-pools providers describe "$PROVIDER" \
     --location=global --workload-identity-pool="$POOL" >/dev/null 2>&1; then
  echo "already exists; updating its condition"
  gcloud iam workload-identity-pools providers update-oidc "$PROVIDER" \
    --location=global \
    --workload-identity-pool="$POOL" \
    --attribute-condition="$ATTR_CONDITION"
else
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
    --location=global \
    --workload-identity-pool="$POOL" \
    --display-name="GitHub Actions OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
    --attribute-condition="$ATTR_CONDITION"
fi

say "Letting that repository impersonate ${SA_EMAIL}"
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${REPO}" >/dev/null

say "Shared secret for POST /internal/cron/tick"
if gcloud secrets describe "$CRON_SECRET_NAME" >/dev/null 2>&1; then
  echo "already exists; leaving the current version in place"
else
  gcloud secrets create "$CRON_SECRET_NAME" --replication-policy=automatic
  # Generated here and never printed. Read it back with
  #   gcloud secrets versions access latest --secret=cron-shared-secret
  openssl rand -base64 32 | tr -d '\n' \
    | gcloud secrets versions add "$CRON_SECRET_NAME" --data-file=-
  echo "created"
fi

SERVICE_URL="$(gcloud run services describe "$SERVICE" --region="$REGION" \
  --format='value(status.url)' 2>/dev/null || true)"
if [ -z "$SERVICE_URL" ]; then
  echo
  echo "!! ${SERVICE} is not deployed in ${REGION} yet, so the scheduler job"
  echo "!! cannot be created. Deploy first, then run this script again —"
  echo "!! everything above is already done and will be skipped."
  exit 0
fi

say "Scheduler job ${CRON_JOB} -> ${SERVICE_URL}/internal/cron/tick"
CRON_SECRET="$(gcloud secrets versions access latest --secret="$CRON_SECRET_NAME")"
SCHEDULER_ARGS=(
  --location="$REGION"
  --schedule="$CRON_SCHEDULE"
  --time-zone="Etc/UTC"
  --uri="${SERVICE_URL}/internal/cron/tick"
  --http-method=POST
  # Give up well before the handler's own 150s limit expires, so a wedged
  # tick is recorded as a failure rather than retried on top of itself.
  --attempt-deadline=160s
  --max-retry-attempts=1
)
# create and update spell the header flag differently: --headers on one,
# --update-headers on the other. Everything else is shared.
if gcloud scheduler jobs describe "$CRON_JOB" --location="$REGION" >/dev/null 2>&1; then
  gcloud scheduler jobs update http "$CRON_JOB" "${SCHEDULER_ARGS[@]}" \
    --update-headers="X-Cron-Secret=${CRON_SECRET}" >/dev/null
  echo "updated"
else
  gcloud scheduler jobs create http "$CRON_JOB" "${SCHEDULER_ARGS[@]}" \
    --headers="X-Cron-Secret=${CRON_SECRET}" >/dev/null
  echo "created"
fi

cat <<EOF

=== Done on the Google Cloud side.

Two things are left, and neither can be done from here.

1. GitHub Actions secret. Settings > Secrets and variables > Actions:

     SUPABASE_DIRECT_URL = the SESSION pooler URL, ending in /monolith_db:
       postgres://postgres.<ref>:<pw>@aws-0-ap-south-1.pooler.supabase.com:5432/monolith_db?sslmode=require
     Not the direct db.<ref>.supabase.co host (IPv6-only; runners have no
     IPv6) and not port 6543 (transaction pooling breaks pg_dump).

   The workflow now needs no other secret: the bucket, the provider and the
   service account are identifiers, not credentials, and live in the
   workflow file. GCP_BACKUP_SA_KEY is no longer used and should be DELETED.

2. Verify it, rather than assuming it. Run the workflow by hand:

     gh workflow run backup-database.yml
     gh run watch

   then confirm a dump actually landed and can be read back:

     backend/scripts/restore-drill.sh

   A backup that has never been restored is a hypothesis, not a backup.

=== A note on the scheduler cadence (${CRON_SCHEDULE})

Every 15 minutes, not every minute. At minScale 0 each tick is a cold start
(measured 6.2s) plus the work, on 2 vCPU. At 15 minutes that is roughly
40,000 vCPU-seconds a month against a free allowance of 180,000, leaving
room for real traffic. At 1 minute it would be about 600,000 — over the
allowance, and billed.

What this costs: reminders and auto-close land within 15 minutes of their
threshold rather than within 1 minute. Notification delivery is NOT affected
— the outbox is woken in-process by the write that created the notification,
so pushes still go out immediately while an instance is up; the scheduled
drain is the retry path for ones that failed.
EOF
