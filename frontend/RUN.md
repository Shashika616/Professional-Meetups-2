# Running the app

Every command below needs `frontend/.env` to exist first — copy
`.env.example` to `.env` and fill in your keys (see `TESTING-NOTES.md` at
the repo root for what `STADIA_MAPS_API_KEY` is and where to get one).
Run everything from `frontend/`.

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
flutter run -d "iPhone 16" --dart-define-from-file=.env
```

**Unlike `chrome`, there's no generic `ios` shortcut** — `flutter run -d
ios` fails with `No supported devices found with name or id matching
'ios'.` (confirmed directly; this isn't a guess). You have to name the
exact simulator by its device name (or its UUID from `flutter devices`),
and that name depends on which simulator model you have booted — `"iPhone
16"` is what this machine's default simulator is called; run `flutter
devices` first if yours is a different model and swap the name in.

If no simulator is running yet:

```bash
flutter emulators --launch apple_ios_simulator
```

## Finding the exact device selector yourself

Whenever one of the commands above doesn't match your setup:

```bash
flutter devices
```

Each row is `Name (category) • Id • Platform • Details` — the `-d` flag
after `flutter run` takes either the `Id` column or the exact `Name`, and
supports prefixes (e.g. `-d B33` would match a device whose id starts
with `B33`, as long as that's unambiguous).
