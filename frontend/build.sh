#!/usr/bin/env bash
# The ONE way to build this app for a device or the emulators.
#
# Every target passes `--dart-define-from-file=.env` (the LinkedIn client id,
# the map provider choice and, for Stadia, its key) AND the right
# GATEWAY_BASE_URL for that target.
# Building with only the gateway URL produces an app that starts and signs
# in with email but has NO MAP on the hosting location step and NO LinkedIn
# sign-in, and nothing in the build output says so. That shipped to a phone
# on 2026-09-13; this script exists so it cannot happen by hand again.
#
# Usage: ./build.sh <target>
#   prod-android     release APKs against the Cloud Run backend, per-ABI
#                    (arm64 for phones) plus the universal one
#   prod-ios         release, unsigned Runner.app + unsigned .ipa for
#                    sideloading (no signing identity on this machine)
#   emulator         debug APK against the local gateway (10.0.2.2:8080)
#   simulator        debug iOS simulator build against localhost:8080
#   verify           re-check existing production outputs, no rebuild
#
# After a prod build the script checks the compiled Dart for the production
# host, the absence of any localhost URL, and that the selected map provider
# is compiled in, and fails loudly if any of those is wrong.
set -euo pipefail
cd "$(dirname "$0")"

PROD_URL="https://meetups-backend-k7eklebcwq-el.a.run.app"
EMULATOR_URL="http://10.0.2.2:8080"
SIMULATOR_URL="http://localhost:8080"

[[ -f .env ]] || { echo "frontend/.env is missing; copy .env.example and fill in the keys" >&2; exit 1; }
# Map provider: osm (default, key-free) or stadia (needs STADIA_MAPS_API_KEY).
MAP_PROVIDER="$(sed -n 's/^MAP_PROVIDER=//p' .env | tr -d '"' | tr -d "'")"
MAP_PROVIDER="${MAP_PROVIDER:-osm}"
STADIA_KEY="$(sed -n 's/^STADIA_MAPS_API_KEY=//p' .env | tr -d '"' | tr -d "'")"
if [[ "$MAP_PROVIDER" == stadia && -z "$STADIA_KEY" ]]; then
  echo "MAP_PROVIDER=stadia but STADIA_MAPS_API_KEY is empty in .env; the map would ship disabled" >&2; exit 1
fi

# Every flutter invocation goes through here so the .env flag can't be
# forgotten. Explicit --dart-define AFTER the file wins for GATEWAY_BASE_URL.
fl() { flutter "$@" --dart-define-from-file=.env; }

# `strings | grep -q` is a trap under pipefail (grep exits early, strings
# gets SIGPIPE, the pipeline reports failure), so the strings are dumped to
# a file once and the checks read that.
check_binary() {
  local label="$1" bin="$2" expect_map_key="$3" dump ok=1
  dump="$(mktemp)"
  strings "$bin" > "$dump"
  grep -q "$PROD_URL" "$dump" || { echo "FAIL $label: production host missing" >&2; ok=0; }
  if grep -Eq '10\.0\.2\.2:8080|localhost:8080' "$dump"; then echo "FAIL $label: a local gateway URL is compiled in" >&2; ok=0; fi
  # The Android map must have its provider compiled in: the OpenFreeMap
  # style host for osm, the Stadia key for stadia. (Dead provider code is
  # tree-shaken, so only the selected one is expected.)
  if [[ "$expect_map_key" == yes ]]; then
    if [[ "$MAP_PROVIDER" == stadia ]]; then
      grep -q "$STADIA_KEY" "$dump" || { echo "FAIL $label: Stadia map key missing (built without .env?)" >&2; ok=0; }
    else
      grep -q "tiles.openfreemap.org" "$dump" || { echo "FAIL $label: OpenFreeMap style host missing" >&2; ok=0; }
      grep -q "photon.komoot.io" "$dump" || { echo "FAIL $label: Photon search host missing" >&2; ok=0; }
    fi
  fi
  rm -f "$dump"
  [[ $ok == 1 ]] && echo "verified $label"
}

verify_android() {
  local apk="$1" tmp so
  tmp="$(mktemp -d)"
  unzip -q -o "$apk" 'lib/*/libapp.so' -d "$tmp"
  so="$(find "$tmp" -name libapp.so | head -1)"
  check_binary "$apk" "$so" yes
  local rc=$?
  rm -rf "$tmp"
  return $rc
}

verify_ios() {
  # iOS draws its maps with Apple Maps (apple_maps_flutter); the Stadia
  # branch is dead code on that target and the AOT compiler strips it, key
  # and all, so its absence there is correct rather than a missing define.
  check_binary "$1" "$1/Frameworks/App.framework/App" no
}

case "${1:-}" in
  prod-android)
    fl build apk --release --split-per-abi --dart-define=GATEWAY_BASE_URL="$PROD_URL"
    fl build apk --release --dart-define=GATEWAY_BASE_URL="$PROD_URL"
    for apk in build/app/outputs/flutter-apk/app-arm64-v8a-release.apk \
               build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk \
               build/app/outputs/flutter-apk/app-release.apk; do
      verify_android "$apk"
    done
    ;;
  prod-ios)
    fl build ios --release --no-codesign --dart-define=GATEWAY_BASE_URL="$PROD_URL"
    verify_ios build/ios/iphoneos/Runner.app
    rm -rf build/ios/ipa-unsigned && mkdir -p build/ios/ipa-unsigned/Payload
    cp -R build/ios/iphoneos/Runner.app build/ios/ipa-unsigned/Payload/
    (cd build/ios/ipa-unsigned && zip -qry TieHere-prod-unsigned.ipa Payload)
    echo "packaged build/ios/ipa-unsigned/TieHere-prod-unsigned.ipa"
    ;;
  emulator)
    fl build apk --debug --dart-define=GATEWAY_BASE_URL="$EMULATOR_URL"
    ;;
  simulator)
    fl build ios --simulator --debug --dart-define=GATEWAY_BASE_URL="$SIMULATOR_URL"
    ;;
  verify)
    # Re-check already-built production outputs without rebuilding.
    for apk in build/app/outputs/flutter-apk/app-arm64-v8a-release.apk \
               build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk \
               build/app/outputs/flutter-apk/app-release.apk; do
      [[ -f "$apk" ]] && verify_android "$apk"
    done
    [[ -d build/ios/iphoneos/Runner.app ]] && verify_ios build/ios/iphoneos/Runner.app
    ;;
  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
