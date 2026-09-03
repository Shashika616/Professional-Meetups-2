#!/usr/bin/env bash
# Convenience wrapper: `flutter run` with .env's credentials auto-passed
# via --dart-define-from-file, so you don't have to type that flag every
# time. See .env.example for what keys go in .env (gitignored) and
# core/config/app_config.dart's doc comment for why this is a compile-time
# flag rather than a runtime-loaded package.
#
# With no args, boots BOTH an iOS simulator and the Android emulator (if
# either isn't already running) and runs on both at once — two background
# `flutter run` processes, one per device, with their output tailed
# together here (Ctrl+C stops both). Pass -d yourself to opt back into
# the plain single-device, fully-interactive-hot-reload behavior instead.
#
# Usage: ./run.sh [any normal `flutter run` args]
#   ./run.sh                          # both iOS simulator and Android emulator
#   ./run.sh -d chrome                # web only
#   ./run.sh -d emulator-5554         # Android only (id from `flutter devices`)
#   ./run.sh -d "iPhone 16"           # iOS only (exact name from `flutter devices`)
#
# Note: -d ios / -d android are NOT valid device selectors in this Flutter
# version — they fail with "No supported devices found with name or id
# matching...". Flutter's -d only matches an exact device id/name or the
# literal well-known ids (chrome, macos, etc.); there's no generic
# per-platform shortcut. See RUN.md for the full picture, verified
# against this project's actual `flutter devices` output.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# The Android emulator to boot/target when more than one is available on
# this machine (`flutter emulators` currently lists both Pixel_10 and
# Pixel_8) — Pixel_10 is the one actually wanted for Android runs. Change
# this if that preference changes later.
PREFERRED_ANDROID_EMULATOR_ID="Pixel_10"

# iOS simulator to boot when none is running — used only by the simctl
# fallback below, not by `flutter emulators --launch` (which has no
# per-device-name selector of its own; "apple_ios_simulator" always means
# "whatever Simulator.app's currently-selected device is").
PREFERRED_IOS_SIMULATOR_NAME="iPhone 16"

if [ ! -f .env ]; then
  echo "frontend/.env not found — copy .env.example to .env and fill in your keys first." >&2
  exit 1
fi

# Locates adb without assuming it's on PATH (it wasn't, on the machine
# this was written on) — used to identify *which* AVD a running Android
# device actually is, since `flutter devices` alone can't tell Pixel_10
# apart from Pixel_8 (their `id`s are just `emulator-<port>`, allocated by
# whichever booted first/still holds that port, not by AVD identity).
find_adb() {
  if command -v adb >/dev/null 2>&1; then
    command -v adb
    return
  fi
  for candidate in \
    "${ANDROID_HOME:-}/platform-tools/adb" \
    "${ANDROID_SDK_ROOT:-}/platform-tools/adb" \
    "$HOME/Library/Android/sdk/platform-tools/adb"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      echo "$candidate"
      return
    fi
  done
}
adb_bin=$(find_adb || true)

# If the caller already picked a device (-d/--device-id), that's a
# single-device run — skip the dual-boot machinery below, but still check
# whether that device is Android and add the GATEWAY_BASE_URL override if
# so (this was missing entirely until a real login failure on Android
# traced back to it: `.env`'s default, localhost, only resolves inside
# the Android emulator to itself, not the host machine — the dual-device
# path below always got this right, this single-device path silently
# never did).
device_selector=""
prev_was_device_flag=false
for arg in "$@"; do
  if [ "$prev_was_device_flag" = true ]; then
    device_selector="$arg"
    break
  fi
  case "$arg" in
    -d | --device-id)
      prev_was_device_flag=true
      ;;
    -d=* | --device-id=*)
      device_selector="${arg#*=}"
      break
      ;;
  esac
done

if [ -n "$device_selector" ] || [ "$prev_was_device_flag" = true ]; then
  gateway_override_present=false
  for arg in "$@"; do
    case "$arg" in
      *GATEWAY_BASE_URL*) gateway_override_present=true ;;
    esac
  done

  single_run_args=()
  if [ -n "$device_selector" ] && [ "$gateway_override_present" = false ]; then
    selector_is_android=$(flutter devices --machine 2>/dev/null | python3 -c "
import json, sys
selector = sys.argv[1].lower()
devices = json.load(sys.stdin)
match = next((d for d in devices if selector in d['id'].lower() or selector in d['name'].lower()), None)
print('true' if match and match['targetPlatform'].startswith('android') else 'false')
" "$device_selector" 2>/dev/null || echo false)
    if [ "$selector_is_android" = true ] || [ "$selector_is_android" = "true" ]; then
      echo "Detected an Android target — adding --dart-define=GATEWAY_BASE_URL=http://10.0.2.2:8080 (.env's default, localhost, doesn't reach the host from inside the Android emulator)."
      single_run_args+=("--dart-define=GATEWAY_BASE_URL=http://10.0.2.2:8080")
    fi
  fi
  exec flutter run --dart-define-from-file=.env "${single_run_args[@]+"${single_run_args[@]}"}" "$@"
fi

# --- Discover this machine's emulator IDs (not hardcoded — `flutter
# emulators` plain-text output, Id | Name | Manufacturer | Platform).
# Capture the output first, then awk over the captured string rather than
# a live pipe: awk's own early `exit` inside a pattern-action block would
# otherwise close the pipe's read end before `flutter emulators` (the
# producer) finishes writing, which sends it SIGPIPE — an intermittent,
# non-deterministic failure under `pipefail`/`set -e` (confirmed by
# running the naive piped version 5x in a row and seeing it fail 4/5
# times with no error output at all).
emulators_list=$(flutter emulators 2>/dev/null || true)
ios_emulator_id=$(printf '%s\n' "$emulators_list" | awk -F'•' '$4 ~ /ios/ {gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}')
android_emulator_ids=$(printf '%s\n' "$emulators_list" | awk -F'•' '$4 ~ /android/ {gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}')
# In case more than one iOS emulator matches, only the first (a pure-bash
# string operation, not another pipe/subprocess, so there's nothing here
# that can race the way the awk `exit` above did).
ios_emulator_id=${ios_emulator_id%%$'\n'*}
# For Android, prefer PREFERRED_ANDROID_EMULATOR_ID specifically (this
# machine has both Pixel_10 and Pixel_8 listed) — fall back to whichever
# Android emulator flutter emulators listed first if that one isn't
# actually available.
if printf '%s\n' "$android_emulator_ids" | grep -qx "$PREFERRED_ANDROID_EMULATOR_ID"; then
  android_emulator_id="$PREFERRED_ANDROID_EMULATOR_ID"
else
  android_emulator_id=${android_emulator_ids%%$'\n'*}
fi

# --- What's already connected, right now. One `flutter devices --machine`
# call per check (it does a real device scan, ~1-2s of subprocess
# overhead) — reused for both the iOS and Android checks below rather
# than queried twice, since this same check also runs on every iteration
# of the wait loop further down and doubling it there doubled the loop's
# real per-iteration time well past its own "up to 3 minutes" claim.
snapshot_devices() {
  flutter devices --machine 2>/dev/null || echo '[]'
}

has_ios_in_snapshot() {
  printf '%s' "$1" | python3 -c '
import json, sys
devices = json.load(sys.stdin)
sys.exit(0 if any(d["targetPlatform"] == "ios" for d in devices) else 1)
'
}

# Prints the connected Android device id (from the given snapshot) whose
# AVD identity matches PREFERRED_ANDROID_EMULATOR_ID, or nothing if it
# isn't connected. Deliberately no cross-emulator fallback here (e.g. to
# Pixel_8) once adb has actually been able to check — if Pixel_10
# specifically isn't up, the caller should boot it, not silently settle
# for whatever else is connected. The only fallback is for adb itself
# being unavailable, where identity can't be verified at all — same
# graceful-degradation philosophy as the rest of this script.
find_preferred_android_device_id_in_snapshot() {
  local candidates candidate_id avd_name
  candidates=$(printf '%s' "$1" | python3 -c '
import json, sys
devices = json.load(sys.stdin)
print("\n".join(d["id"] for d in devices if d["targetPlatform"].startswith("android")))
')
  [ -z "$candidates" ] && return
  if [ -z "$adb_bin" ]; then
    printf '%s\n' "$candidates" | head -n1
    return
  fi
  while IFS= read -r candidate_id; do
    [ -z "$candidate_id" ] && continue
    avd_name=$("$adb_bin" -s "$candidate_id" emu avd name 2>/dev/null || true)
    avd_name=$(printf '%s\n' "$avd_name" | head -n1 | tr -d '\r')
    if [ "$avd_name" = "$PREFERRED_ANDROID_EMULATOR_ID" ]; then
      printf '%s\n' "$candidate_id"
      return
    fi
  done <<<"$candidates"
}

# `flutter emulators --launch apple_ios_simulator` is a silent no-op
# (exit 0, no output, no device boots) if Simulator.app is already running
# but has no device actually booted inside it — a real, reproducible state
# (e.g. Simulator.app left open from a previous session, or quit-out-from
# under a booted device). That's the actual cause of this script appearing
# to hang at the wait loop below: `has_ios` never flips true because
# nothing ever boots, so it spins for the full 3-minute timeout every time.
# `xcrun simctl boot <udid>` boots reliably in that same state (confirmed:
# `flutter emulators --launch` left zero devices booted; `simctl boot`
# immediately booted one), so use it directly instead of going through
# `flutter emulators --launch` for iOS.
boot_ios_simulator() {
  local udid
  udid=$(xcrun simctl list devices available -j 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
target = sys.argv[1]
for devices in data.get('devices', {}).values():
    for d in devices:
        if d['name'] == target:
            print(d['udid'])
            sys.exit()
" "$PREFERRED_IOS_SIMULATOR_NAME" 2>/dev/null || true)
  if [ -z "$udid" ]; then
    # Named simulator not found on this machine — fall back to Flutter's
    # own resolution, which is at least not a no-op when nothing is open.
    flutter emulators --launch "$ios_emulator_id"
    return
  fi
  xcrun simctl boot "$udid" 2>/dev/null || true
  open -a Simulator
}

devices_snapshot=$(snapshot_devices)

has_ios=false
has_ios_in_snapshot "$devices_snapshot" && has_ios=true

android_device_id=$(find_preferred_android_device_id_in_snapshot "$devices_snapshot" || true)
has_android=$([ -n "$android_device_id" ] && echo true || echo false)

if [ "$has_ios" = false ] && [ -n "$ios_emulator_id" ]; then
  echo "Booting an iOS simulator ($PREFERRED_IOS_SIMULATOR_NAME)..."
  boot_ios_simulator
elif [ -z "$ios_emulator_id" ]; then
  echo "No iOS simulator emulator found via 'flutter emulators' — skipping it."
fi

if [ "$has_android" = false ] && [ -n "$android_emulator_id" ]; then
  echo "Booting the Android emulator ($android_emulator_id)..."
  flutter emulators --launch "$android_emulator_id"
elif [ -z "$android_emulator_id" ]; then
  echo "No Android emulator found via 'flutter emulators' — skipping it."
fi

# --- Wait for whichever of the two we just asked to boot (skip waiting
# for one we couldn't find an emulator for at all).
want_ios=$([ -n "$ios_emulator_id" ] && echo true || echo false)
want_android=$([ -n "$android_emulator_id" ] && echo true || echo false)

if [ "$has_ios" = false ] || [ "$has_android" = false ]; then
  echo "Waiting for the emulator(s) to come online (up to 3 minutes)..."
  for _ in $(seq 1 90); do
    devices_snapshot=$(snapshot_devices)
    has_ios_in_snapshot "$devices_snapshot" && has_ios=true
    android_device_id=$(find_preferred_android_device_id_in_snapshot "$devices_snapshot" || true)
    [ -n "$android_device_id" ] && has_android=true
    ios_ready=$([ "$want_ios" = false ] || [ "$has_ios" = true ] && echo true || echo false)
    android_ready=$([ "$want_android" = false ] || [ "$has_android" = true ] && echo true || echo false)
    if [ "$ios_ready" = true ] && [ "$android_ready" = true ]; then
      break
    fi
    sleep 2
  done
fi

# --- Both flutter run processes below get the same --dart-defines, but
# GATEWAY_BASE_URL normally needs to differ per platform (backend/
# README.md's documented gotcha: localhost for iOS, 10.0.2.2 for Android —
# the latter can't reach the host machine any other way). The Mac's own
# LAN IP reaches the gateway from *both* the iOS simulator (shares the
# host's network) and the Android emulator (its NAT can route to the
# host's real IP, not just the 10.0.2.2 alias) — auto-detected here so
# dual-device mode actually works for both without manual config, unless
# the caller already passed their own GATEWAY_BASE_URL override, which
# always wins.
gateway_override_present=false
for arg in "$@"; do
  case "$arg" in
    *GATEWAY_BASE_URL*) gateway_override_present=true ;;
  esac
done

extra_args=()
if [ "$gateway_override_present" = false ]; then
  lan_ip=$(ipconfig getifaddr "$(route get default 2>/dev/null | awk '/interface:/{print $2}')" 2>/dev/null || true)
  if [ -n "$lan_ip" ]; then
    echo "Using http://$lan_ip:8080 as GATEWAY_BASE_URL for both devices — pass your own --dart-define=GATEWAY_BASE_URL=... to override."
    extra_args+=("--dart-define=GATEWAY_BASE_URL=http://$lan_ip:8080")
  fi
fi

# --- Launch on exactly the two emulators — not `-d all`. `-d all` also
# grabs *every* other connected device (this machine's own macOS desktop
# target, Chrome web), which "run in both emulators" doesn't mean, and
# `flutter run`'s -d flag has no comma-separated-list form to name two
# specific devices in one invocation (it's a single id, or the literal
# 'all') — so two precisely-targeted devices means two separate
# processes. One final snapshot, in case anything changed since the wait
# loop above last checked.
devices_snapshot=$(snapshot_devices)
ios_device_id=$(printf '%s' "$devices_snapshot" | python3 -c '
import json, sys
devices = json.load(sys.stdin)
print(next((d["id"] for d in devices if d["targetPlatform"] == "ios"), ""))
' || true)
android_device_id=$(find_preferred_android_device_id_in_snapshot "$devices_snapshot" || true)

run_args=(--dart-define-from-file=.env "${extra_args[@]+"${extra_args[@]}"}" "$@")
log_dir=$(mktemp -d)
pids=()

cleanup() {
  for pid in "${pids[@]+"${pids[@]}"}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup INT TERM EXIT

if [ -n "$ios_device_id" ]; then
  echo "Starting on iOS ($ios_device_id) — log: $log_dir/ios.log"
  flutter run -d "$ios_device_id" "${run_args[@]}" >"$log_dir/ios.log" 2>&1 &
  pids+=("$!")
fi
if [ -n "$android_device_id" ]; then
  if [ -n "$adb_bin" ]; then
    echo "Starting on Android ($PREFERRED_ANDROID_EMULATOR_ID, $android_device_id) — log: $log_dir/android.log"
  else
    echo "Starting on Android ($android_device_id — adb not found, couldn't confirm this is $PREFERRED_ANDROID_EMULATOR_ID specifically) — log: $log_dir/android.log"
  fi
  flutter run -d "$android_device_id" "${run_args[@]}" >"$log_dir/android.log" 2>&1 &
  pids+=("$!")
fi

if [ ${#pids[@]} -eq 0 ]; then
  echo "No iOS or Android device came online — nothing to run." >&2
  exit 1
fi

echo "Both running in the background — this script's own terminal can't"
echo "send hot-reload keystrokes to two processes at once. Use your"
echo "editor's Flutter integration (the .vscode/launch.json configs also"
echo "added alongside this script), or 'flutter attach -d <id>' in"
echo "another terminal, for interactive hot reload on either one."
echo "Tailing both logs below; Ctrl+C stops both."
tail -f "$log_dir"/*.log
