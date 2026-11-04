#!/usr/bin/env bash
# Renders docs/deploy/service.yaml.template into a Cloud Run manifest
# (tracker #100). The deploy workflow runs it with values from the
# `production` environment's secrets; locally, export the same variables
# first (runbook §3). The output is never committed (.gitignore).
#
# Usage: scripts/render-service-yaml.sh [output]   (default: service.yaml)
#
# Every ${NAME} in the template must be listed below as REQUIRED (refuses to
# render when empty) or OPTIONAL (renders, with a warning saying what stays
# off). A placeholder in neither list is an error, so a new setting cannot
# be added to the template without deciding which it is.
# cmd/monolith/deploy_manifest_test.go checks the lists against the template.
set -euo pipefail
cd "$(dirname "$0")/.."

TEMPLATE=../docs/deploy/service.yaml.template
# The manifest test checks a backend/service.yaml only when it starts with
# this line, so a hand-edited file from before this script is not mistaken
# for a rendered one.
RENDERED_MARKER="# Rendered from docs/deploy/service.yaml.template by scripts/render-service-yaml.sh. Do not edit."
OUT="${1:-service.yaml}"

REQUIRED=(
  REVISION
  GOOGLE_CLIENT_ID
  APPLE_SERVICES_ID
  LINKEDIN_CLIENT_ID
  TWILIO_ACCOUNT_SID
  TWILIO_PHONE_NUMBER
  GMAIL_ADDRESS
  MIN_CREDITS_APP_VERSION
  OTEL_EXPORTER
)
OPTIONAL=(
  "ANALYTICS_ARCHIVE_BUCKET:raw analytics are dropped after retention with no archive, and the report is not stored"
  "ANALYTICS_REPORT_RECIPIENTS:the daily report is stored but not emailed"
  "MIN_SUPPORTED_APP_VERSION:no app build is told to update"
  "APPLE_APP_STORE_ISSUER_ID:iOS purchases fail closed (503)"
  "APPLE_APP_STORE_KEY_ID:iOS purchases fail closed (503)"
  "GOOGLE_PUBSUB_PUSH_AUDIENCE:Google store notifications are refused (503)"
  "GOOGLE_PUBSUB_PUSH_SERVICE_ACCOUNT:Google store notifications are refused (503)"
  "TEST_OTP_BYPASS_PHONES:the test phone numbers need real codes"
  "TEST_OTP_BYPASS_EMAILS:the seeded .test accounts cannot sign in"
)

known=" ${REQUIRED[*]} "
for entry in "${OPTIONAL[@]}"; do known+="${entry%%:*} "; done

failed=0
for name in $(grep -o '\${[A-Z0-9_]*}' "$TEMPLATE" | tr -d '${}' | sort -u); do
  if [[ "$known" != *" $name "* ]]; then
    echo "render: \${$name} is in the template but in neither list in $0" >&2
    failed=1
  fi
done

check_value() {
  local name="$1" value="${!1-}"
  # Every placeholder sits inside a double-quoted YAML scalar. A quote, a
  # backslash, a newline or a dollar would end it early or be re-expanded.
  if [[ "$value" == *'"'* || "$value" == *'\'* || "$value" == *$'\n'* || "$value" == *'$'* ]]; then
    echo "render: $name holds a quote, backslash, newline or \$; refusing" >&2
    failed=1
  fi
}

for name in "${REQUIRED[@]}"; do
  if [ -z "${!name-}" ]; then
    echo "render: $name is required and empty" >&2
    failed=1
  fi
  check_value "$name"
done
for entry in "${OPTIONAL[@]}"; do
  name="${entry%%:*}"
  if [ -z "${!name-}" ]; then
    echo "render: warning: $name is empty: ${entry#*:}" >&2
    export "$name="
  fi
  check_value "$name"
done
if ! [[ "${REVISION-}" =~ ^r[0-9]+[a-z]?$ ]]; then
  echo "render: REVISION must look like r38, got '${REVISION-}'" >&2
  failed=1
fi
[ "$failed" = 0 ] || exit 1

vars=""
for name in "${REQUIRED[@]}"; do vars+="\${$name} "; done
for entry in "${OPTIONAL[@]}"; do vars+="\${${entry%%:*}} "; done
export "${REQUIRED[@]}"
# Only the listed names are substituted, so any other $ in the template is
# left alone.
{
  echo "$RENDERED_MARKER"
  envsubst "$vars" <"$TEMPLATE"
} >"$OUT"
echo "render: wrote $OUT for revision $REVISION" >&2
