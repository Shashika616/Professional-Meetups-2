import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;

import 'package:professional_connections_platform/core/services/push_notification_service.dart';

/// Real Firebase-backed [PushNotificationService] (ADR-030, round-10) —
/// swaps in behind the interface Round 9 built; every existing call site
/// (`AuthSessionNotifier`'s token registration, `AppShell`'s message
/// listener) already targets that interface and needs no changes. Talks to
/// the real `professional-meetups-976d2` Firebase project via
/// `google-services.json`/`GoogleService-Info.plist`/`firebase_options.dart`,
/// all already placed and verified — `main.dart` calls
/// `Firebase.initializeApp` before this is ever constructed.
///
/// **Apple Developer Program is deliberately deferred** (not purchased
/// yet, see TESTING-NOTES.md) — this class is fully real and correct on
/// iOS too, not stubbed out. iOS just won't actually *deliver* a push
/// until an APNs Authentication Key is uploaded to this Firebase project
/// later — that's a console-side config gap, not a code gap here. Android
/// needs no such key and is fully live today, testable directly via
/// Firebase console's own "Compose notification" tool.
class FirebasePushNotificationService implements PushNotificationService {
  FirebasePushNotificationService({
    FirebaseMessaging? messaging,
    this.onTokenRefreshed,
  }) : _injectedMessaging = messaging;

  final FirebaseMessaging? _injectedMessaging;

  /// Resolved lazily on first real use ([initialize]/[currentToken]), not
  /// eagerly in the constructor — `FirebaseMessaging.instance` itself
  /// resolves the default `Firebase.app()` the moment it's first touched,
  /// which throws if `Firebase.initializeApp()` was never called (e.g.
  /// under `flutter test`, which never runs `main()`). Deferring this
  /// keeps merely *constructing* this class — done eagerly by
  /// `pushNotificationServiceProvider` — always safe regardless of
  /// whether Firebase has actually been initialized in this process; the
  /// two methods that do touch it both wrap the access in try/catch.
  FirebaseMessaging get _messaging =>
      _injectedMessaging ?? FirebaseMessaging.instance;

  /// Round-9's call sites only ever register a device token once, at
  /// session-restore/sign-in — a real gap for a long-lived session, since
  /// FCM rotates tokens periodically. Set by whoever constructs this
  /// service (`app_providers.dart`, to the same `registerDeviceToken`
  /// path `AuthSessionNotifier` already calls at sign-in) so a refreshed
  /// token reaches the backend the same way — no second registration
  /// mechanism, just re-invoking the existing one on
  /// `FirebaseMessaging.instance.onTokenRefresh`. Wired here, inside
  /// [initialize] (called once from `AppShell.initState()`, same
  /// lifecycle point as the `messages`-stream subscriptions below), not
  /// in `AppShell` itself — `AppShell` only knows the
  /// [PushNotificationService] interface, which has no token-refresh
  /// stream of its own (deliberately: that's Firebase-specific, and the
  /// interface stays implementation-agnostic), so this is the only place
  /// that can wire it without either changing the interface or reaching
  /// into `FirebaseMessaging` from outside this file.
  final void Function(String token)? onTokenRefreshed;

  final StreamController<PushMessage> _messagesController =
      StreamController<PushMessage>.broadcast();
  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _onMessageSubscription;
  StreamSubscription<RemoteMessage>? _onMessageOpenedAppSubscription;
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    // Safe to call multiple times (interface contract) — idempotent, not
    // re-subscribing on a second call.
    if (_initialized) return;
    _initialized = true;

    try {
      // Fail-safe, non-throwing — a user who declines notification
      // permission (or a platform/emulator that errors on this call
      // entirely) must not break anything else in the app. The interface
      // makes no distinction between "denied" and "unavailable"; neither
      // should stop app startup.
      await _messaging.requestPermission();
    } catch (_) {
      // Ignored — see doc comment above.
    }

    try {
      // onMessage = it arrived while the user was looking at the app. FCM
      // deliberately shows NO system banner in that case, so this is the
      // only path by which the user can be told.
      _onMessageSubscription = FirebaseMessaging.onMessage.listen(
        (message) => _messagesController.add(
          pushMessageFromRemoteMessage(
            message,
            source: PushMessageSource.foreground,
          ),
        ),
      );
      // onMessageOpenedApp = they tapped the banner. They have already read
      // it; the app should act on it, not repeat it back.
      _onMessageOpenedAppSubscription = FirebaseMessaging.onMessageOpenedApp
          .listen(
            (message) => _messagesController.add(
              pushMessageFromRemoteMessage(
                message,
                source: PushMessageSource.opened,
              ),
            ),
          );

      final callback = onTokenRefreshed;
      if (callback != null) {
        _tokenRefreshSubscription = _messaging.onTokenRefresh.listen(callback);
      }
    } catch (_) {
      // Same fail-safe reasoning as requestPermission above — e.g. no
      // Firebase app registered in this process (flutter test never runs
      // main()'s Firebase.initializeApp) must not crash whatever called
      // initialize().
    }
  }

  @override
  Future<String?> currentToken() async {
    try {
      // iOS-specific gotcha: calling getToken() before the APNs token
      // itself is available returns null/throws — getAPNSToken() must
      // resolve first. Android has no APNs token at all (FCM talks to
      // Android devices directly), so this branch only applies to iOS.
      // defaultTargetPlatform (not dart:io's Platform.isIOS, which throws
      // on web — this codebase already builds for web, see
      // ios_map_location_step.dart's matching comment on this exact
      // tradeoff) is the platform check already established elsewhere in
      // this codebase for this same reason.
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final apnsToken = await _messaging.getAPNSToken();
        if (apnsToken == null) return null;
      }
      return await _messaging.getToken();
    } catch (_) {
      // Never throw — every call site already treats a null token as the
      // normal "not available yet" case (interface contract), which
      // covers both a genuinely transient state and this round's known,
      // accepted gap: iOS won't have a real APNs token at all until the
      // deferred APNs key is uploaded to the Firebase project.
      return null;
    }
  }

  @override
  Stream<PushMessage> get messages => _messagesController.stream;

  /// Not part of the [PushNotificationService] interface — nothing in
  /// this codebase's other singleton-provider services has a dispose path
  /// either (`AppShell`/the app itself outlives this service for the
  /// whole process lifetime in production). Exposed for tests that
  /// construct their own instance and want to release its subscriptions/
  /// close its `StreamController` cleanly rather than leaking it.
  void dispose() {
    _tokenRefreshSubscription?.cancel();
    _onMessageSubscription?.cancel();
    _onMessageOpenedAppSubscription?.cancel();
    _messagesController.close();
  }
}

/// Pure `RemoteMessage → PushMessage` mapping (ADR-030, round-10 Step 5) —
/// deliberately factored out of [FirebasePushNotificationService] as a
/// public top-level function so it's the one piece of this service that
/// can be meaningfully unit-tested under `flutter test` without a real
/// platform channel (constructing a [RemoteMessage] directly needs no
/// plugin, unlike everything else this class does).
///
/// `data['type']`/`data['meetup_id']` are what the backend's
/// `OutboxPushSender` actually sends today (see
/// `services/meetup/internal/service`'s `notifyMeetupClosed` /
/// `notifications.Sender`) — `notification`'s title/body fall back to
/// empty strings, never null, matching [PushMessage]'s own non-nullable
/// fields (a data-only message with no `notification` block is valid FCM
/// shape).
PushMessage pushMessageFromRemoteMessage(
  RemoteMessage message, {
  PushMessageSource source = PushMessageSource.foreground,
}) {
  return PushMessage(
    type: message.data['type'] ?? '',
    meetupId: message.data['meetup_id'],
    title: message.notification?.title ?? '',
    body: message.notification?.body ?? '',
    source: source,
  );
}
