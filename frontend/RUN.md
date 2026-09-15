# Running the app

Every command below needs `frontend/.env` to exist first — copy
`.env.example` to `.env` and fill in your keys. The Android map defaults to
OpenStreetMap (`MAP_PROVIDER=osm`: OpenFreeMap tiles + Photon search, no
key); set `MAP_PROVIDER=stadia` plus `STADIA_MAPS_API_KEY` only to opt back
into Stadia Maps. Run everything from `frontend/`.

```bash
cp .env.example .env   # first time only, then edit .env
```

## Both iOS simulator and Android emulator at once

```bash
./run.sh
```

Boots whichever of the two isn't already running, then launches on both
as two separate `flutter run` processes with their output tailed
together in this one terminal. Ctrl+C stops both. See `run.sh`'s own
header comment for why it's two processes rather than one `flutter run -d
all` (the latter also grabs this machine's macOS/Chrome targets, which
isn't what "both emulators" means, and there's real per-platform
`GATEWAY_BASE_URL` handling this script does for you — see below).

This machine has two Android emulators (`Pixel_10` and `Pixel_8`) —
`run.sh` specifically targets **Pixel_10**, verified via `adb -s <id> emu
avd name` (not just "whichever Android device happens to be connected"),
so it won't accidentally launch on Pixel_8 even if that one happens to
already be running. Its own `Starting on Android (Pixel_10, emulator-5554)`
line confirms which one it picked.

Because the two processes run in the background, this script can't
forward hot-reload keystrokes (`r`/`R`/`q`) to either one. For real
interactive hot-reload development, use one of the single-platform
commands below directly in your own terminal, or the `.vscode/launch.json`
configs added alongside this script (VS Code's Run panel → "Flutter (.env
— iOS/default)" or "Flutter (.env — Android emulator)").

## Web only

```bash
flutter run -d chrome --dart-define-from-file=.env
```

`chrome` is one of the few device selectors Flutter treats as a stable,
built-in shortcut — this one just works.

## Android only

This machine has two Android emulators set up (`flutter emulators` lists
`Pixel_10` and `Pixel_8`) — **Pixel_10 is the one to use**. `run.sh` (the
dual-device command above) already knows this and targets it specifically
(see its `PREFERRED_ANDROID_EMULATOR_ID` at the top); for a manual
Android-only run:

```bash
flutter emulators --launch Pixel_10   # skip if it's already running
flutter run -d emulator-5554 --dart-define-from-file=.env \
  --dart-define=GATEWAY_BASE_URL=http://10.0.2.2:8080
```

`emulator-5554` is the standard id Android's tooling assigns to the
*first* running emulator instance, regardless of which AVD it is —
launching `Pixel_8` instead would get the same id. If you're not sure
which AVD is actually behind `emulator-5554` (e.g. both might already be
running, or you're not sure which one you booted), confirm before running:

```bash
adb -s emulator-5554 emu avd name   # prints the real AVD id, e.g. "Pixel_10"
```

(`adb` lives at `$ANDROID_HOME/platform-tools/adb`, or
`~/Library/Android/sdk/platform-tools/adb` if `$ANDROID_HOME` isn't set —
it's not necessarily on `PATH`.) If a second emulator is *also* running
simultaneously, it gets the next port (`emulator-5556`, `5558`, ...); run
`flutter devices` to see everything currently connected.

The `GATEWAY_BASE_URL` override is required here: `.env`'s default value
is `http://localhost:8080` (correct for the iOS simulator, which shares
the host machine's network), but the Android emulator can't reach
`localhost` that way — `10.0.2.2` is its own special alias back to the
host (`backend/README.md`'s documented gotcha).

## iOS only

```bash
flutter run -d "iPhone 18 Pro" --dart-define-from-file=.env
```

**Unlike `chrome`, there's no generic `ios` shortcut** — `flutter run -d
ios` fails with `No supported devices found with name or id matching
'ios'.` (confirmed directly; this isn't a guess). You have to name the
exact simulator by its device name (or its UUID from `flutter devices`),
and that name depends on which simulator model you have booted — with
Xcode 27 / iOS 27 the devices are `iPhone 18 Pro`, `iPhone 17e`, `iPhone
Air` and so on (an `iPhone 16` may still exist on an older iOS 18.3
runtime); run `flutter devices` first and swap the name in. `run.sh` picks
the newest runtime automatically (`PREFERRED_IOS_SIMULATOR_NAMES`).

Xcode 27 note: Simulator.app is gone; the device window is
**DeviceHub.app** inside Xcode (`open -a
/Applications/Xcode.app/Contents/Applications/DeviceHub.app`). A device
booted with `xcrun simctl boot` runs fine without the window.

If no simulator is running yet:

```bash
flutter emulators --launch apple_ios_simulator
```

## Building for real devices and production

Use `./build.sh`; do not type `flutter build` by hand. The script passes
`--dart-define-from-file=.env` for every target, sets the right
`GATEWAY_BASE_URL`, and for production builds checks the compiled Dart for
the production host, the absence of any localhost URL, and the presence of
the selected map provider. A build made with only
`--dart-define=GATEWAY_BASE_URL=...` compiles and runs but ships without
the LinkedIn client id (and, on the Stadia provider, without the map key),
silently. That happened once (2026-09-13); the script is the guard.

```bash
./build.sh prod-android   # release APKs vs Cloud Run: arm64/armeabi/x86_64 + universal
./build.sh prod-ios       # unsigned release Runner.app + .ipa for sideloading
./build.sh emulator       # debug APK against the local gateway (10.0.2.2:8080)
./build.sh simulator      # debug iOS simulator build against localhost:8080
```

Outputs: `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` (install
this one on a phone), `build/ios/iphoneos/Runner.app` and
`build/ios/ipa-unsigned/TieHere-prod-unsigned.ipa`. The split APKs and the
universal APK carry different version codes, so uninstall one flavour before
installing the other.

If you must call `flutter build` directly, the invariant is: `.env` first,
gateway override second, e.g.
`flutter build apk --release --dart-define-from-file=.env --dart-define=GATEWAY_BASE_URL=https://meetups-backend-k7eklebcwq-el.a.run.app`.

## Finding the exact device selector yourself

Whenever one of the commands above doesn't match your setup:

```bash
flutter devices
```

Each row is `Name (category) • Id • Platform • Details` — the `-d` flag
after `flutter run` takes either the `Id` column or the exact `Name`, and
supports prefixes (e.g. `-d B33` would match a device whose id starts
with `B33`, as long as that's unambiguous).
