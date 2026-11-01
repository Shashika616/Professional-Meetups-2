#!/usr/bin/env bash
# Load test for the analytics ingest (plan 29D): 200 batches a second for 60
# seconds against a monolith built from the working tree, on the LOCAL test
# database (monolith_db_test in the docker-compose Postgres). Never
# production.
#
# It starts its own monolith on port 9191 with a throwaway internal secret
# (generated here, never printed), runs cmd/analyticsload, waits for the
# buffer to flush, then reports p95 latency, drops, and how many events
# were actually stored.
#
# Requires: the compose Postgres running (`docker compose up -d postgres`),
# Go, openssl. Usage: scripts/analytics-load.sh [rate] [seconds] [events-per-batch]
set -euo pipefail

cd "$(dirname "$0")/.."
RATE="${1:-200}"
SECONDS_TO_RUN="${2:-60}"
EVENTS="${3:-10}"
PORT=9191
DB=monolith_db_test
WORK="$(mktemp -d)"
MONO_PID=""
cleanup() {
  if [ -n "$MONO_PID" ]; then kill "$MONO_PID" 2>/dev/null || true; wait "$MONO_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

psql_test() { docker compose exec -T postgres psql -U app -d "$DB" -tAc "$1"; }

go build -o "$WORK/monolith" ./cmd/monolith
go build -o "$WORK/load" ./cmd/analyticsload

# The test database must exist and be migrated: the integration tests do
# both (go test ./internal/modules/analytics/).
psql_test "SELECT 1" >/dev/null

INTERNAL_GRPC_SHARED_SECRET="$(openssl rand -hex 32)"
export INTERNAL_GRPC_SHARED_SECRET

MONOLITH_PORT=$PORT \
DATABASE_URL="postgres://app:app@localhost:5432/$DB?sslmode=disable" \
LINKEDIN_CLIENT_ID=load-test LINKEDIN_CLIENT_SECRET=load-test LINKEDIN_REDIRECT_URI=http://localhost/load-test \
WORK_EMAIL_HMAC_KEY_PATH=secrets/work_email_hmac.key \
OTEL_EXPORTER=none \
  "$WORK/monolith" >"$WORK/monolith.log" 2>&1 &
MONO_PID=$!

for _ in $(seq 1 50); do
  if nc -z localhost "$PORT" 2>/dev/null; then break; fi
  sleep 0.2
done
nc -z localhost "$PORT" || { echo "the monolith did not start:"; tail -20 "$WORK/monolith.log"; exit 1; }

BEFORE="$(psql_test "SELECT count(*) FROM analytics.events")"
"$WORK/load" -addr "localhost:$PORT" -rate "$RATE" -duration "${SECONDS_TO_RUN}s" -events "$EVENTS" | tee "$WORK/result.json"
sleep 4 # two flush intervals
AFTER="$(psql_test "SELECT count(*) FROM analytics.events")"

echo "stored_events: $((AFTER - BEFORE))"
echo "flush_failures_logged: $(grep -c 'flush failed' "$WORK/monolith.log" || true)"
