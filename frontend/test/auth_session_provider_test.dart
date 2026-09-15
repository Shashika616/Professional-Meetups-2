import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/models/public_profile.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/services/push_notification_service.dart';
import 'package:professional_connections_platform/core/services/token_refresher.dart';
import 'package:professional_connections_platform/core/storage/session_storage.dart';

import 'support/fake_secure_storage_platform.dart';
import 'support/scripted_meetup_service.dart';

/// Same no-op behavior as [NoOpPushNotificationService] (`currentToken()`
/// always returns `null`, `messages` never emits) but with a call counter —
/// ADR-030's own no-op implementation deliberately stays minimal/untracked
/// (it's production code, not a test double), so this local fake is what
/// lets a test prove the login/session-restore call site genuinely reaches
/// `currentToken()`, not just that nothing crashes.
class _TrackingNoOpPushNotificationService implements PushNotificationService {
  _TrackingNoOpPushNotificationService({this.token});

  /// What currentToken() answers; null models a device without a token.
  final String? token;
  int currentTokenCallCount = 0;
  int deleteTokenCallCount = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<String?> currentToken() async {
    currentTokenCallCount++;
    return token;
  }

  @override
  Future<void> deleteToken() async {
    deleteTokenCallCount++;
  }

  @override
  Stream<PushMessage> get messages => const Stream<PushMessage>.empty();
}

/// Models what a REAL push service does on a device that has not been asked
/// for notification permission yet: no token. On iOS `getToken()` returns
/// null until the APNs token exists, which it does not until
/// `requestPermission()` has run — and `requestPermission()` runs inside
/// `initialize()`.
///
/// This is the behaviour [PushNotificationService]'s own contract describes
/// ("sets up whatever the concrete implementation needs BEFORE
/// currentToken()/messages are useful"), so a caller that skips
/// [initialize] gets null and registers nothing.
class _UninitializedYieldsNullPushService implements PushNotificationService {
  bool initialized = false;
  int currentTokenCallCount = 0;

  @override
  Future<void> initialize() async => initialized = true;

  @override
  Future<String?> currentToken() async {
    currentTokenCallCount++;
    return initialized ? 'fcm-token-1' : null;
  }

  @override
  Future<void> deleteToken() async {}

  @override
  Stream<PushMessage> get messages => const Stream<PushMessage>.empty();
}

/// Every method throws except getProfile() — the notifier's build() path
/// under test never needs the others, and UnimplementedError makes it
/// obvious if that assumption ever stops holding.
class _FakeAuthService implements AuthService {
  @override
  Future<PublicProfile> getPublicProfile(String userId) =>
      throw UnimplementedError('not exercised by this test');

  // ADR-002 § 3. The shortest route to a fresh session, which the sign-out
  // tests use to model "someone signed in again" while a revoke is still
  // in flight.
  @override
  Future<AuthSession> guestSignup({required bool ageConfirmedOver18}) async =>
      _sessionExpiringIn(const Duration(minutes: 15), accessToken: 'guest');

  _FakeAuthService(this._profile);

  final UserProfile _profile;

  @override
  Future<UserProfile> getProfile() async => _profile;

  @override
  Future<AuthSession> signInWithLinkedIn({
    required bool ageConfirmedOver18,
  }) async => throw UnimplementedError();

  @override
  Future<AuthSession> signInWithApple({
    required bool ageConfirmedOver18,
  }) async => throw UnimplementedError();

  @override
  Future<AuthSession> signInWithGoogle({
    required bool ageConfirmedOver18,
  }) async => throw UnimplementedError();

  @override
  Future<AuthSession> signUpWithEmail({
    required String email,
    required String code,
    required bool ageConfirmedOver18,
  }) async => throw UnimplementedError();

  @override
  Future<AuthSession> loginWithEmail({
    required String email,
    required String code,
  }) async => throw UnimplementedError();

  @override
  Future<AuthSession> linkLinkedIn() async => throw UnimplementedError();

  @override
  Future<int> startEmailSignupOtp(String email) async =>
      throw UnimplementedError();

  @override
  Future<int> startEmailLoginOtp(String email) async =>
      throw UnimplementedError();

  @override
  Future<UserProfile> completeProfileSetup({
    required String fullName,
    String? companyName,
    String? companyEmail,
  }) async => throw UnimplementedError();

  @override
  Future<AuthSession> refreshSession(String refreshToken) async =>
      throw UnimplementedError();

  /// Recorded so the sign-out test can check what the one server request
  /// carried. [logoutStarted] completes when logout is entered and
  /// [logoutGate] holds it there, which is how the test proves the local
  /// sign-out never waits on the network.
  int logoutCallCount = 0;
  String? lastLogoutRefreshToken;
  String? lastLogoutAccessToken;
  String? lastLogoutFcmToken;
  final logoutStarted = Completer<void>();
  final logoutGate = Completer<void>();

  @override
  Future<void> logout(
    String refreshToken, {
    String? accessToken,
    String? fcmToken,
  }) async {
    logoutCallCount++;
    lastLogoutRefreshToken = refreshToken;
    lastLogoutAccessToken = accessToken;
    lastLogoutFcmToken = fcmToken;
    if (!logoutStarted.isCompleted) logoutStarted.complete();
    await logoutGate.future;
  }

  @override
  Future<int> startPhoneVerification(String phoneNumber) async =>
      throw UnimplementedError();

  @override
  Future<AuthSession> verifyPhoneCode(String phoneNumber, String code) async =>
      throw UnimplementedError();

  @override
  Future<int> startPersonalEmailVerification(String email) async =>
      throw UnimplementedError();

  @override
  Future<AuthSession> verifyPersonalEmailCode(
    String email,
    String code,
  ) async => throw UnimplementedError();

  @override
  Future<AuthSession> submitPersonalDetails(
    String legalName,
    String address,
  ) async => throw UnimplementedError();

  @override
  Future<int> startCorporateEmailVerification(String email) async =>
      throw UnimplementedError();

  @override
  Future<AuthSession> verifyCorporateEmailCode(
    String email,
    String code,
    String companyName,
  ) async => throw UnimplementedError();

  @override
  Future<TrustedContact> addTrustedContact({
    required String name,
    String phoneNumber = '',
    String email = '',
  }) async => throw UnimplementedError();

  @override
  Future<List<TrustedContact>> listTrustedContacts() async =>
      throw UnimplementedError();

  @override
  Future<void> removeTrustedContact(String contactId) async =>
      throw UnimplementedError();

  @override
  Future<int> triggerSos({
    required String contextMessage,
    required double latitude,
    required double longitude,
  }) async => throw UnimplementedError();

  @override
  Future<void> updateLastKnownLocation({
    required double latitude,
    required double longitude,
  }) async => throw UnimplementedError();
}

AuthSession _sessionExpiringIn(Duration delta, {String accessToken = 'a1'}) {
  return AuthSession(
    userId: 'user-1',
    accessToken: accessToken,
    refreshToken: 'refresh-1',
    trustLevel: 1,
    isNewUser: false,
    accessTokenExpiresAt: DateTime.now().add(delta),
    fullName: 'Ada Lovelace',
    profilePhotoUrl: '',
  );
}

void main() {
  late SecureSessionStorage storage;

  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
    storage = SecureSessionStorage(storage: const FlutterSecureStorage());
  });

  test(
    'build() resolves to a logged-in state carrying the refreshed session, '
    'not the stale one, when the stored access token has already expired',
    () async {
      final stale = _sessionExpiringIn(const Duration(minutes: -5));
      await storage.saveSession(stale);
      final refreshed = _sessionExpiringIn(
        const Duration(minutes: 15),
        accessToken: 'fresh-access-token',
      );

      final container = ProviderContainer(
        overrides: [
          sessionStorageProvider.overrideWithValue(storage),
          tokenRefresherProvider.overrideWithValue(
            TokenRefresher(
              storage: storage,
              refreshSession: (token) async => refreshed,
            ),
          ),
          authServiceProvider.overrideWithValue(
            _FakeAuthService(
              const UserProfile(id: 'user-1', fullName: 'Ada Lovelace'),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final state = await container.read(authSessionProvider.future);

      expect(state.isLoggedIn, isTrue);
      expect(state.session!.accessToken, 'fresh-access-token');
    },
  );

  test(
    'signOut() signs out locally at once and, in the background, sends '
    'ONE logout request carrying the refresh token, the access token and '
    'this device\'s push token, then deletes the token on the device',
    () async {
      final valid = _sessionExpiringIn(const Duration(minutes: 15));
      await storage.saveSession(valid);
      final pushService = _TrackingNoOpPushNotificationService(
        token: 'fcm-device-token',
      );
      final auth = _FakeAuthService(
        const UserProfile(id: 'user-1', fullName: 'Ada Lovelace'),
      );

      final container = ProviderContainer(
        overrides: [
          sessionStorageProvider.overrideWithValue(storage),
          tokenRefresherProvider.overrideWithValue(
            TokenRefresher(
              storage: storage,
              refreshSession: (token) async =>
                  throw StateError('should never be called'),
            ),
          ),
          authServiceProvider.overrideWithValue(auth),
          pushNotificationServiceProvider.overrideWithValue(pushService),
          meetupServiceProvider.overrideWithValue(ScriptedMeetupService()),
        ],
      );
      addTearDown(container.dispose);
      await container.read(authSessionProvider.future);

      // Returns while the server call is still held open by the gate: the
      // local sign-out is what the screen waits on, nothing else.
      await container.read(authSessionProvider.notifier).signOut();
      expect(container.read(authSessionProvider).value?.isLoggedIn, isFalse);
      expect(await storage.loadSession(), isNull);

      await auth.logoutStarted.future;
      expect(auth.logoutCallCount, 1);
      expect(auth.lastLogoutRefreshToken, valid.refreshToken);
      expect(auth.lastLogoutAccessToken, valid.accessToken);
      expect(auth.lastLogoutFcmToken, 'fcm-device-token');
      // The device-side delete waits for the server call, so a token is
      // never deleted under a registration the server still holds.
      expect(pushService.deleteTokenCallCount, 0);

      auth.logoutGate.complete();
      await pumpEventQueue();
      expect(pushService.deleteTokenCallCount, 1);
    },
  );

  test('signOut() keeps the device token when another session signed in '
      'before the background revoke finished', () async {
    final valid = _sessionExpiringIn(const Duration(minutes: 15));
    await storage.saveSession(valid);
    final pushService = _TrackingNoOpPushNotificationService(
      token: 'fcm-device-token',
    );
    final auth = _FakeAuthService(
      const UserProfile(id: 'user-1', fullName: 'Ada Lovelace'),
    );

    final container = ProviderContainer(
      overrides: [
        sessionStorageProvider.overrideWithValue(storage),
        tokenRefresherProvider.overrideWithValue(
          TokenRefresher(
            storage: storage,
            refreshSession: (token) async =>
                throw StateError('should never be called'),
          ),
        ),
        authServiceProvider.overrideWithValue(auth),
        pushNotificationServiceProvider.overrideWithValue(pushService),
        meetupServiceProvider.overrideWithValue(ScriptedMeetupService()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authSessionProvider.future);

    await container.read(authSessionProvider.notifier).signOut();
    await auth.logoutStarted.future;

    // A new sign-in lands while the old sign-out's server call is in
    // flight. (The guest path is the shortest way to a live session here.)
    await container
        .read(authSessionProvider.notifier)
        .guestSignup(ageConfirmedOver18: true);
    expect(container.read(authSessionProvider).value?.isLoggedIn, isTrue);

    auth.logoutGate.complete();
    await pumpEventQueue();
    expect(
      pushService.deleteTokenCallCount,
      0,
      reason:
          'deleting the token would silence the account that just signed in',
    );
  });

  test('forceSignOut() moves state from logged-in to a logged-out '
      'AuthSessionState', () async {
    final valid = _sessionExpiringIn(const Duration(minutes: 15));
    await storage.saveSession(valid);

    final container = ProviderContainer(
      overrides: [
        sessionStorageProvider.overrideWithValue(storage),
        tokenRefresherProvider.overrideWithValue(
          TokenRefresher(
            storage: storage,
            refreshSession: (token) async =>
                throw StateError('should never be called'),
          ),
        ),
        authServiceProvider.overrideWithValue(
          _FakeAuthService(
            const UserProfile(id: 'user-1', fullName: 'Ada Lovelace'),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final initial = await container.read(authSessionProvider.future);
    expect(initial.isLoggedIn, isTrue);

    container.read(authSessionProvider.notifier).forceSignOut();

    final after = container.read(authSessionProvider).value;
    expect(after, const AuthSessionState());
    expect(after!.isLoggedIn, isFalse);
  });

  test('ADR-030 (round-9): session-restore calls '
      'pushNotificationService.currentToken(), but does NOT call '
      'registerDeviceToken since NoOpPushNotificationService always returns '
      'null — the "wired but genuinely inert until Firebase exists" '
      'behavior this round\'s scaffolding is supposed to have', () async {
    final valid = _sessionExpiringIn(const Duration(minutes: 15));
    await storage.saveSession(valid);
    final pushService = _TrackingNoOpPushNotificationService();
    final meetupService = ScriptedMeetupService();

    final container = ProviderContainer(
      overrides: [
        sessionStorageProvider.overrideWithValue(storage),
        tokenRefresherProvider.overrideWithValue(
          TokenRefresher(
            storage: storage,
            refreshSession: (token) async =>
                throw StateError('should never be called'),
          ),
        ),
        authServiceProvider.overrideWithValue(
          _FakeAuthService(
            const UserProfile(id: 'user-1', fullName: 'Ada Lovelace'),
          ),
        ),
        pushNotificationServiceProvider.overrideWithValue(pushService),
        meetupServiceProvider.overrideWithValue(meetupService),
      ],
    );
    addTearDown(container.dispose);

    final state = await container.read(authSessionProvider.future);
    expect(state.isLoggedIn, isTrue);

    // The registration call is fire-and-forget (unawaited) so it never
    // delays session establishment — give its one microtask hop (the
    // NoOp's currentToken()) a real event-loop turn to actually run
    // before asserting on it.
    await Future<void>.delayed(Duration.zero);

    expect(
      pushService.currentTokenCallCount,
      1,
      reason: 'the call site must genuinely reach currentToken()',
    );
    expect(
      meetupService.registerDeviceTokenCallCount,
      0,
      reason: 'must stay inert — currentToken() returned null',
    );
  });

  test('session-restore initializes the push service before asking it for a '
      'token — otherwise the FIRST session on a device registers nothing, and '
      'that user gets no notifications at all until the app is next '
      'relaunched', () async {
    final valid = _sessionExpiringIn(const Duration(minutes: 15));
    await storage.saveSession(valid);
    final pushService = _UninitializedYieldsNullPushService();
    final meetupService = ScriptedMeetupService();

    final container = ProviderContainer(
      overrides: [
        sessionStorageProvider.overrideWithValue(storage),
        tokenRefresherProvider.overrideWithValue(
          TokenRefresher(
            storage: storage,
            refreshSession: (token) async =>
                throw StateError('should never be called'),
          ),
        ),
        authServiceProvider.overrideWithValue(
          _FakeAuthService(
            const UserProfile(id: 'user-1', fullName: 'Ada Lovelace'),
          ),
        ),
        pushNotificationServiceProvider.overrideWithValue(pushService),
        meetupServiceProvider.overrideWithValue(meetupService),
      ],
    );
    addTearDown(container.dispose);

    await container.read(authSessionProvider.future);
    // Fire-and-forget, and now two awaits deep (initialize, then
    // currentToken), so drain rather than hopping a fixed number of turns.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      pushService.initialized,
      isTrue,
      reason:
          'AppShell.initState() initializes too, but that runs AFTER '
          'sign-in has already asked for the token',
    );
    expect(meetupService.registerDeviceTokenCallCount, 1);
    expect(meetupService.lastRegisteredDeviceToken, 'fcm-token-1');
  });
}
