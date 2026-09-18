#!/usr/bin/env bash
# Nightly logical backup of the production database (ADR-007, Plan 20 Fix 2).
#
# Supabase's free tier has no managed backups and no point-in-time
# recovery, so this is the backup. It runs from GitHub Actions
# (.github/workflows/backup-database.yml) once a day and on demand.
#
# Required environment:
#   SUPABASE_DIRECT_URL  the DIRECT connection URL (db.<ref>.supabase.co:5432).
#                        Never the pooler URL: transaction pooling hands out
#                        a different server connection per transaction, which
#                        a long-running pg_dump cannot work over.
#   BACKUP_GCS_BUCKET    bucket name, without gs://, e.g. meetups-db-backups.
#
# Output: one custom-format dump (`pg_dump -Fc`, what the runbook's restore
# notes assume; restore with pg_restore) named backup-<UTC timestamp>.dump,
# uploaded to gs://$BACKUP_GCS_BUCKET/, local copy removed. Retention is the
# bucket's lifecycle policy (backup-lifecycle.json), not this script.
#
# Any failure exits non-zero. A missed backup must fail the workflow run
# loudly; a silently skipped step here is worse than no script at all.
set -euo pipefail

: "${SUPABASE_DIRECT_URL:?SUPABASE_DIRECT_URL is not set}"
: "${BACKUP_GCS_BUCKET:?BACKUP_GCS_BUCKET is not set}"

command -v pg_dump >/dev/null || { echo "pg_dump not found on PATH" >&2; exit 1; }
command -v gsutil  >/dev/null || { echo "gsutil not found on PATH" >&2; exit 1; }

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
file="backup-${stamp}.dump"
trap 'rm -f -- "$file"' EXIT

echo "pg_dump -> ${file}"
pg_dump "$SUPABASE_DIRECT_URL" -Fc --no-owner --no-privileges -f "$file"

# An empty or tiny file means the dump did not really happen (a wrong URL
# that still connects, an empty database). Refuse to upload it as a backup.
size=$(wc -c < "$file")
if [ "$size" -lt 1024 ]; then
  echo "dump is only ${size} bytes; refusing to treat that as a backup" >&2
  exit 1
fi
echo "dump size: ${size} bytes"

echo "upload -> gs://${BACKUP_GCS_BUCKET}/${file}"
gsutil -q cp "$file" "gs://${BACKUP_GCS_BUCKET}/${file}"

# Read it back from the bucket: an upload that returned 0 but left nothing
# behind must not count as done.
gsutil -q stat "gs://${BACKUP_GCS_BUCKET}/${file}"
echo "backup complete: gs://${BACKUP_GCS_BUCKET}/${file}"
