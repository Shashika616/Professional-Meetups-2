#!/usr/bin/env bash
# Restore the newest backup into a throwaway local database and check it
# actually contains the schema and the data (Plan 28 #95).
#
# WHY THIS EXISTS
#
# Between 2026-09-25 and 2026-10-22 this project had a backup workflow, a
# backup script, a documented restore procedure, and no backups. Every run
# failed at the authentication step, nobody was told, and the gap was found
# only when the production database was already gone.
#
# A backup pipeline that has never been restored from is a hypothesis. This
# script is how it becomes a fact, and it is cheap enough to run after any
# change to the backup path.
#
# WHAT IT DOES
#
#   1. Finds the newest object in the backup bucket.
#   2. Downloads it.
#   3. Restores it into a fresh database in the LOCAL docker-compose
#      Postgres — never into Supabase, and never over anything.
#   4. Asserts the restored database has the expected schemas, a plausible
#      table count, and a schema_migrations version matching the migrations
#      directory.
#   5. Drops the throwaway database.
#
# Requires: gcloud (authenticated), pg_restore and psql 17+, and the local
# compose stack running (`docker compose up -d postgres`).
set -euo pipefail

BUCKET="${BACKUP_GCS_BUCKET:-meetups-db-backups-740861671089}"
# The local compose Postgres, never a remote one. Overridable only so the
# drill can run against a scratch instance in CI.
LOCAL_URL="${RESTORE_DRILL_URL:-postgres://postgres:postgres@localhost:5432/postgres}"
DRILL_DB="restore_drill_$(date -u +%Y%m%d%H%M%S)"

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
workdir="$(mktemp -d)"
cleanup() {
  rm -rf -- "$workdir"
  # Drop the throwaway database even if an assertion failed; leaving these
  # behind turns a weekly drill into a disk-space problem.
  psql "$LOCAL_URL" -q -c "DROP DATABASE IF EXISTS ${DRILL_DB};" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Refuse to point at anything that is not local. This script creates and
# drops databases; a typo that aimed it at Supabase would be unrecoverable.
case "$LOCAL_URL" in
  *localhost*|*127.0.0.1*|*@postgres:*) ;;
  *)
    echo "restore-drill: refusing to run against a non-local database: ${LOCAL_URL%%\?*}" >&2
    echo "This script creates and drops databases. It is for the local stack only." >&2
    exit 1
    ;;
esac

echo "=== newest backup in gs://${BUCKET}"
newest="$(gsutil ls "gs://${BUCKET}/backup-*.dump" | sort | tail -1)"
if [ -z "$newest" ]; then
  echo "no backups in the bucket at all" >&2
  exit 1
fi
echo "$newest"

# A backup nobody has taken in days is a finding in itself, not a pass.
newest_stamp="$(basename "$newest" | sed -E 's/^backup-([0-9]{8})T.*/\1/')"
age_days=$(( ( $(date -u +%s) - $(date -u -j -f %Y%m%d "$newest_stamp" +%s 2>/dev/null \
            || date -u -d "$newest_stamp" +%s) ) / 86400 ))
echo "age: ${age_days} day(s)"
if [ "$age_days" -gt 2 ]; then
  echo "!! the newest backup is ${age_days} days old; the nightly job is not working" >&2
  exit 1
fi

echo
echo "=== downloading"
gsutil -q cp "$newest" "$workdir/backup.dump"
size=$(wc -c < "$workdir/backup.dump")
echo "${size} bytes"

echo
echo "=== restoring into ${DRILL_DB}"
psql "$LOCAL_URL" -q -c "CREATE DATABASE ${DRILL_DB};"
drill_url="${LOCAL_URL%/*}/${DRILL_DB}"
# --no-owner/--no-privileges: the dump was taken that way, and the local
# role set does not match Supabase's. Errors are NOT ignored.
pg_restore --no-owner --no-privileges --exit-on-error \
  -d "$drill_url" "$workdir/backup.dump"

echo
echo "=== checking what came back"
fail=0
check() { # check <label> <sql> <expected-comparison>
  local label="$1" sql="$2" want="$3"
  local got
  got="$(psql "$drill_url" -tAc "$sql")"
  if [ "$got" "$want" ]; then
    printf '  ok   %-28s %s\n' "$label" "$got"
  else
    printf '  FAIL %-28s %s\n' "$label" "$got"
    fail=1
  fi
}

# The schemas this app owns. A dump missing one of these restored "cleanly"
# and is still useless.
for schema in auth meetup notification; do
  got="$(psql "$drill_url" -tAc \
    "SELECT count(*) FROM information_schema.schemata WHERE schema_name='${schema}';")"
  if [ "$got" = "1" ]; then
    printf '  ok   schema %-21s present\n' "$schema"
  else
    printf '  FAIL schema %-21s MISSING\n' "$schema"
    fail=1
  fi
done

check "tables" \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema IN ('auth','meetup','notification');" \
  "-ge 15"

# The restored schema version must match what this checkout expects. A
# backup one migration behind the code restores fine and then fails at
# runtime, which is exactly the surprise a drill is meant to remove.
expected="$(ls "${repo_root}/backend/migrations"/*.up.sql \
  | sed -E 's|.*/([0-9]+)_.*|\1|' | sort -n | tail -1 | sed 's/^0*//')"
actual="$(psql "$drill_url" -tAc "SELECT version FROM schema_migrations;" 2>/dev/null || echo "none")"
if [ "$actual" = "$expected" ]; then
  printf '  ok   %-28s %s\n' "schema_migrations" "$actual"
else
  printf '  FAIL %-28s backup has %s, migrations dir has %s\n' \
    "schema_migrations" "$actual" "$expected"
  fail=1
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "RESTORE DRILL FAILED: the newest backup did not restore into a usable database." >&2
  exit 1
fi
echo "RESTORE DRILL PASSED: ${newest} restores into a usable database."
