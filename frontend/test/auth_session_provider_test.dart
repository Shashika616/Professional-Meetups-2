import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
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
  int currentTokenCallCount = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<String?> currentToken() async {
    currentTokenCallCount++;
    return null;
  }

  @override
  Stream<PushMessage> get messages => const Stream<PushMessage>.empty();
}

/// Every method throws except getProfile() — the notifier's build() path
/// under test never needs the others, and UnimplementedError makes it
/// obvious if that assumption ever stops holding.
class _FakeAuthService implements AuthService {
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

  @override
  Future<void> logout(String refreshToken) async {}

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
}
