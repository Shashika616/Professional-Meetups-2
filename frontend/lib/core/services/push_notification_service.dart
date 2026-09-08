import 'dart:async';

/// Contract for push-notification delivery (ADR-030, round-9 scaffolding).
/// Same `abstract interface class` + swappable-implementation pattern as
/// [AuthService]/[MeetupService] (`CLAUDE.md`'s "Service-contract
/// pattern") and the backend's `SmsSender`/`EmailSender`/`ReverseGeocoder`
/// shape — one real implementation slots in behind this later without
/// touching any call site.
///
/// Deliberately app-defined types ([PushMessage], not `firebase_messaging`'s
/// `RemoteMessage`) — no `firebase_core`/`firebase_messaging` dependency
/// exists in this app yet (no Firebase project to point them at, see
/// TESTING-NOTES.md / ADR-030), so this interface can't reference that
/// package's types even if it wanted to. When a real
/// `FirebasePushNotificationService` is built, it translates
/// `RemoteMessage` into [PushMessage] internally — callers of this
/// interface never see the Firebase-specific type.
abstract interface class PushNotificationService {
  /// Sets up whatever the concrete implementation needs before
  /// [currentToken]/[messages] are useful (e.g. a real implementation would
  /// request notification permission and initialize the Firebase SDK here).
  /// Safe to call multiple times.
  Future<void> initialize();

  /// The current device's push token, or `null` if none is available yet
  /// (not configured, permission denied, still initializing, or — today —
  /// no real implementation exists at all). Callers must always handle
  /// `null` gracefully; it is not an error state.
  Future<String?> currentToken();

  /// Incoming push messages, translated to this app's own lightweight
  /// [PushMessage] shape. May never emit — that's the normal, expected
  /// state with [NoOpPushNotificationService] until a real implementation
  /// exists.
  Stream<PushMessage> get messages;
}

/// A push message, translated from whatever the underlying platform SDK
/// hands the real implementation into this app's own shape — deliberately
/// not `firebase_messaging`'s `RemoteMessage`; see [PushNotificationService]'s
/// own doc comment for why.
/// How a [PushMessage] reached the app.
///
/// The distinction is load-bearing: a message that ARRIVES while the app is
/// open needs the app to say something, because FCM shows no system banner
/// in the foreground. A message the user TAPPED in the tray needs no notice
/// at all — they just read it, and repeating it as a toast over the screen
/// they were sent to is noise.
enum PushMessageSource {
  /// Arrived while the app was open and in front of the user.
  foreground,

  /// The user tapped a system notification and the app came forward.
  opened,
}

class PushMessage {
  const PushMessage({
    required this.type,
    this.meetupId,
    required this.title,
    required this.body,
    this.source = PushMessageSource.foreground,
  });

  /// See [PushMessageSource].
  final PushMessageSource source;

  /// e.g. `"meetup_closed"` — what a listener switches on to decide what,
  /// if anything, to invalidate/navigate to. An open string, not an enum,
  /// since the backend is the source of truth for what types exist and new
  /// ones shouldn't require a client enum change to just be ignored safely.
  final String type;

  /// Populated when [type] refers to a specific meetup (e.g.
  /// `"meetup_closed"`); `null` for a type that doesn't.
  final String? meetupId;

  final String title;
  final String body;
}

/// The only implementation that exists today (ADR-030) — no Firebase
/// project exists yet, so there is nothing for a real implementation to
/// talk to. `currentToken()` always returns `null` and [messages] never
/// emits; every call site wired against [PushNotificationService] (login/
/// session-restore's token-registration call, the app-level message
/// listener) must already handle that gracefully, since it's the real,
/// current production behavior, not a test stub. Swapping in a real
/// `FirebasePushNotificationService` later is a single provider-binding
/// change in `app_providers.dart`, not a call-site rewrite — mirrors how
/// `AuthService`/`MeetupService` moved from `Mock*` to `Http*`
/// implementations without their call sites changing.
class NoOpPushNotificationService implements PushNotificationService {
  @override
  Future<void> initialize() async {}

  @override
  Future<String?> currentToken() async => null;

  @override
  Stream<PushMessage> get messages => const Stream<PushMessage>.empty();
}
