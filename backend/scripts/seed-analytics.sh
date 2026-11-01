#!/usr/bin/env bash
# Seeds a realistic week of analytics events and billing-side credit events
# into the LOCAL database, aggregates it, and builds the daily report for
# its last day (plan 29F). Local only: the seeder refuses any host but
# localhost.
#
# Usage: scripts/seed-analytics.sh [accounts] [days] [end YYYY-MM-DD]
# Writes the workbook to ./analytics-report-<end>.xlsx and prints its path.
set -euo pipefail
cd "$(dirname "$0")/.."

ACCOUNTS="${1:-500}"
DAYS="${2:-7}"
END="${3:-$(TZ=Asia/Colombo date -v-1d +%F 2>/dev/null || TZ=Asia/Colombo date -d yesterday +%F)}"
export DATABASE_URL="${DATABASE_URL:-postgres://app:app@localhost:5432/monolith_db?sslmode=disable}"

go run ./cmd/analyticsseed --accounts="$ACCOUNTS" --days="$DAYS" --end="$END"
go run ./cmd/analyticsreport --date="$END" --out="analytics-report-$END.xlsx"
echo "report: $(pwd)/analytics-report-$END.xlsx"
