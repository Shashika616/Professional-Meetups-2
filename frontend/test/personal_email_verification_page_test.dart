import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/storage/session_storage.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/verification/personal_email_verification_page.dart';

import 'support/fake_secure_storage_platform.dart';

class _FakeAuthService implements AuthService {
  _FakeAuthService({
    required this.startResult,
    this.verifyResult,
    this.verifyError,
  });

  final int startResult;
  final AuthSession? verifyResult;
  final Object? verifyError;
  int startCallCount = 0;
  int verifyCallCount = 0;
  String? lastEmail;
  String? lastCode;

  @override
  Future<int> startPersonalEmailVerification(String email) async {
    startCallCount++;
    lastEmail = email;
    return startResult;
  }

  @override
  Future<AuthSession> verifyPersonalEmailCode(String email, String code) async {
    verifyCallCount++;
    lastCode = code;
    if (verifyError != null) throw verifyError!;
    return verifyResult!;
  }

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
  Future<UserProfile> getProfile() async =>
      const UserProfile(id: 'user-1', fullName: 'Ada Lovelace');

  @override
  Future<int> startPhoneVerification(String phoneNumber) async =>
      throw UnimplementedError();

  @override
  Future<AuthSession> verifyPhoneCode(String phoneNumber, String code) async =>
      throw UnimplementedError();

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

final _updatedSession = AuthSession(
  userId: 'user-1',
  accessToken: 'new.a.b',
  refreshToken: 'new-refresh',
  trustLevel: 2,
  isNewUser: false,
  accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
  fullName: 'Ada Lovelace',
  profilePhotoUrl: '',
);

Widget _appWith(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Navigator(
        onGenerateRoute: (settings) => MaterialPageRoute(
          builder: (context) => const PersonalEmailVerificationPage(),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
  });

  testWidgets('Skip pops the screen without ever calling '
      'startPersonalEmailVerification or verifyPersonalEmailCode', (
    tester,
  ) async {
    final auth = _FakeAuthService(startResult: 60);
    final container = ProviderContainer(
      overrides: [
        authServiceProvider.overrideWithValue(auth),
        sessionStorageProvider.overrideWithValue(
          SecureSessionStorage(storage: const FlutterSecureStorage()),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();

    expect(find.byType(PersonalEmailVerificationPage), findsNothing);
    expect(auth.startCallCount, 0);
    expect(auth.verifyCallCount, 0);
  });

  testWidgets('a wrong code shows the mapped error and stays on this screen', (
    tester,
  ) async {
    final auth = _FakeAuthService(
      startResult: 60,
      verifyError: const InvalidVerificationCodeException(
        'That code is incorrect.',
      ),
    );
    final container = ProviderContainer(
      overrides: [
        authServiceProvider.overrideWithValue(auth),
        sessionStorageProvider.overrideWithValue(
          SecureSessionStorage(storage: const FlutterSecureStorage()),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'ada@example.com');
    await tester.pump();
    await tester.tap(find.byType(PrimaryButton).first);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '000000');
    await tester.pump();
    await tester.tap(find.byType(PrimaryButton).first);
    await tester.pump();
    await tester.pump();

    expect(find.text('That code is incorrect.'), findsOneWidget);
    expect(find.byType(PersonalEmailVerificationPage), findsOneWidget);
  });

  testWidgets(
    'a correct code updates the session and profile immediately, then pops',
    (tester) async {
      final auth = _FakeAuthService(
        startResult: 60,
        verifyResult: _updatedSession,
      );
      final container = ProviderContainer(
        overrides: [
          authServiceProvider.overrideWithValue(auth),
          sessionStorageProvider.overrideWithValue(
            SecureSessionStorage(storage: const FlutterSecureStorage()),
          ),
        ],
      );
      addTearDown(container.dispose);

      // See phone_verification_page_test.dart for why this is needed —
      // completeVerification()'s manual state assignment would otherwise
      // race authSessionProvider's own initial build().
      await container.read(authSessionProvider.future);

      await tester.pumpWidget(_appWith(container));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'ada@example.com');
      await tester.pump();
      await tester.tap(find.byType(PrimaryButton).first);
      await tester.pumpAndSettle();

      expect(auth.lastEmail, 'ada@example.com');

      await tester.enterText(find.byType(TextField), '123456');
      await tester.pump();
      await tester.tap(find.byType(PrimaryButton).first);
      await tester.pumpAndSettle();

      expect(auth.verifyCallCount, 1);
      expect(auth.lastCode, '123456');
      expect(find.byType(PersonalEmailVerificationPage), findsNothing);

      final sessionState = container.read(authSessionProvider).value!;
      expect(sessionState.session!.accessToken, 'new.a.b');
      expect(sessionState.profile, isNotNull);
    },
  );
}
