# Frontend plan — Round 10: real Firebase push wiring (swap the no-op)

See `docs/04-decisions/adr-030-active-meetup-refresh-fix-and-push-notification-scaffolding.md` and `docs/00-project/action-tracker.md` § 4b-23 for full context. Round 9 built a `PushNotificationService` interface and a `NoOpPushNotificationService`, with all call sites already wired (token registration at session-restore/sign-in, message-driven provider invalidation in `AppShell`). This round swaps in a real implementation — **no call-site changes should be needed**, only a new implementation class and the provider binding.

Config files already placed and verified: `frontend/android/app/google-services.json`, `frontend/ios/Runner/GoogleService-Info.plist`, `frontend/lib/firebase_options.dart` (hand-authored from the real config values, Android + iOS only).

**Scope constraint, confirmed with Shashika: Apple Developer Program is deferred, not yet purchased.** Build the full real client for both platforms — the code should be correct and complete for iOS too — but iOS will not actually receive a delivered push until the APNs key is uploaded later (a console-side gap, not a code gap). Android must be fully real and testable today. Do not skip or half-build the iOS half; do not block on the APNs key existing.

## Step 1 — Dependencies

Add `firebase_core` and `firebase_messaging` to `pubspec.yaml`. Confirm current stable versions against pub.dev at implementation time rather than trusting any version number in this plan (same discipline this codebase already applies to `sign_in_with_apple`/`google_sign_in` — see their comments in `pubspec.yaml`).

## Step 2 — Android native wiring

- Root `frontend/android/build.gradle.kts`: add `id("com.google.gms.google-services") version "4.5.0" apply false` to the `plugins` block (confirm latest version at implementation time).
- App `frontend/android/app/build.gradle.kts`: apply `id("com.google.gms.google-services")`.
- Check `flutter.minSdkVersion`'s actual resolved value against the `firebase_messaging` version you add's stated minimum — bump explicitly in this file only if the Flutter-default value is actually insufficient (don't bump speculatively).
- `google-services.json` is already at `frontend/android/app/google-services.json` — don't move or regenerate it.

## Step 3 — iOS native wiring

- Add the Push Notifications capability and Background Modes → Remote notifications to the `Runner` target — this is project/entitlements configuration, not a paid-account action, so it can and should be added now even though the Apple Developer Program isn't purchased yet. If Xcode's automatic-signing UI genuinely blocks adding this capability without a signed-in paid team, do it by directly editing `Runner.xcodeproj`'s project file / a `Runner.entitlements` file instead (the `xcodeproj` Ruby gem is already used elsewhere in this project for exactly this kind of native project-file surgery — see `TESTING-NOTES.md`'s `LocalSearchChannel.swift` addition for the precedent) rather than giving up on the capability entirely.
- `GoogleService-Info.plist` is already at `frontend/ios/Runner/GoogleService-Info.plist` — don't move or regenerate it. Confirm it's actually added to the Xcode project's file references / Copy Bundle Resources build phase (a file existing on disk isn't enough, per this project's own prior `LocalSearchChannel.swift` lesson).

## Step 4 — App initialization

`main.dart`: before `runApp`, call `await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)` (import `firebase_options.dart`, already in place at `lib/firebase_options.dart`). Register a top-level background message handler function, annotated `@pragma('vm:entry-point')`, passed to `FirebaseMessaging.onBackgroundMessage(...)` — this function runs in a separate isolate and must call `Firebase.initializeApp()` itself before doing anything else.

## Step 5 — `FirebasePushNotificationService`

New class implementing the existing `PushNotificationService` interface (`lib/core/services/push_notification_service.dart`) — do not change the interface itself.

- `initialize()`: request notification permission via `FirebaseMessaging.instance.requestPermission()`; log and continue (don't throw) if denied — a user who declines notifications shouldn't break anything else in the app.
- `currentToken()`: **on iOS specifically, the APNs token must be available before requesting the FCM token** — a known platform gotcha (calling `getToken()` too early on iOS returns null/throws). Check for and await `FirebaseMessaging.instance.getAPNSToken()` first on iOS, or use the equivalent guard this package version recommends. Wrap the whole thing in try/catch and return `null` on any failure — never throw, matching how Round 9's call sites already treat a null token as the normal "not available yet" case.
- `messages`: merge `FirebaseMessaging.onMessage` (foreground) and `FirebaseMessaging.onMessageOpenedApp` (user tapped a notification that opened/resumed the app) into the existing `Stream<PushMessage>` shape — map `RemoteMessage.data['type']`/`data['meetup_id']`/`notification?.title`/`notification?.body` onto `PushMessage`'s existing fields (don't change `PushMessage` itself). Keep this mapping logic as a small, pure, separately-testable function (e.g. `PushMessage _fromRemoteMessage(RemoteMessage m)`) rather than inlining it — this is the one part of this service that CAN be meaningfully unit-tested without a real Firebase plugin.

## Step 6 — Token refresh (a real gap Round 9's scaffolding didn't cover)

Round 9's call sites only register a token at session-restore and post-sign-in — neither fires again if FCM rotates the token mid-session (which it does, periodically, per Firebase's own behavior). Add a listener on `FirebaseMessaging.instance.onTokenRefresh` that calls the same registration path Round 9 already built (`AuthSessionNotifier`'s existing token-registration method, or an equivalent one you expose) whenever a new token is issued. Wire this subscription in `FirebasePushNotificationService.initialize()` or `AppShell`, whichever fits this codebase's existing lifecycle-management pattern better — say which you chose and why.

## Step 7 — Wire the real implementation in

`app_providers.dart`: change `pushNotificationServiceProvider`'s binding from `NoOpPushNotificationService` to `FirebasePushNotificationService`. Update the doc comment (matching `authServiceProvider`'s own "real implementation as of ADR-XXX" convention) rather than leaving it describing the no-op.

## Tests

- Unit test the pure `RemoteMessage → PushMessage` mapping function directly (construct a `RemoteMessage` with known `data`/`notification` fields, assert the mapped `PushMessage`).
- Confirm `NoOpPushNotificationService` itself is left untouched and its existing tests still pass (it may still be useful for future test fixtures even though it's no longer the default binding).
- Full Firebase plugin behavior (`initialize()`, `currentToken()`, real message delivery) is not meaningfully unit-testable under `flutter test` without a real platform channel — say so plainly in your report rather than fabricating a test that doesn't actually exercise the real plugin. This mirrors this codebase's existing, already-accepted pattern for `geolocator`/`flutter_secure_storage` (faked platform interfaces for what's fakeable, honest disclosure for what isn't).

## Do not

- Do not change the `PushNotificationService` interface or any existing call site (`AuthSessionNotifier`, `AppShell`'s message subscription) — Round 9 already built these correctly against the interface; only the implementation swaps.
- Do not skip the iOS half of this work because the Apple Developer Program isn't purchased yet — build it completely; only actual APNs delivery is blocked, not the code.
- Do not regenerate or move `google-services.json`/`GoogleService-Info.plist`/`firebase_options.dart` — all three are already in place with real, verified values.

## Full checklist

`flutter analyze --fatal-infos`, `dart format --set-exit-if-changed`, `flutter test` — report the real total from the test runner's own summary line. Also report: were you able to run a real `flutter build apk`/`flutter build ios --simulator --no-codesign` in this environment to confirm the native wiring actually compiles (this project has had a real macOS/Xcode toolchain available in at least one prior session pass — check and use it if present; if not available here, say so plainly rather than assuming it compiles).
