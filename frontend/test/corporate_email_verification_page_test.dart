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
import 'package:professional_connections_platform/features/verification/corporate_email_verification_page.dart';

import 'support/fake_secure_storage_platform.dart';

class _FakeAuthService implements AuthService {
  _FakeAuthService({this.startResult, this.startError, this.verifyResult});

  final int? startResult;
  final Object? startError;
  final AuthSession? verifyResult;
  int startCallCount = 0;
  int verifyCallCount = 0;
  String? lastEmail;
  String? lastCompanyName;

  @override
  Future<int> startCorporateEmailVerification(String email) async {
    startCallCount++;
    lastEmail = email;
    if (startError != null) throw startError!;
    return startResult!;
  }

  @override
  Future<AuthSession> verifyCorporateEmailCode(
    String email,
    String code,
    String companyName,
  ) async {
    verifyCallCount++;
    lastCompanyName = companyName;
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

Widget _appWith(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Navigator(
        onGenerateRoute: (settings) => MaterialPageRoute(
          builder: (context) => const CorporateEmailVerificationPage(),
        ),
      ),
    ),
  );
}

ProviderContainer _containerWith(AuthService auth) {
  return ProviderContainer(
    overrides: [
      authServiceProvider.overrideWithValue(auth),
      sessionStorageProvider.overrideWithValue(
        SecureSessionStorage(storage: const FlutterSecureStorage()),
      ),
    ],
  );
}

void main() {
  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
  });

  testWidgets('Skip pops the screen without ever calling '
      'startCorporateEmailVerification', (tester) async {
    final auth = _FakeAuthService(startResult: 60);
    final container = _containerWith(auth);
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();

    expect(find.byType(CorporateEmailVerificationPage), findsNothing);
    expect(auth.startCallCount, 0);
  });

  testWidgets('typing a free-mail address shows the client-side hint without '
      'blocking submission', (tester) async {
    final auth = _FakeAuthService(startResult: 60);
    final container = _containerWith(auth);
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Acme Corp'); // company name
    await tester.enterText(fields.at(1), 'ada@gmail.com'); // email
    await tester.pump();

    expect(
      find.textContaining('This looks like a personal email address'),
      findsOneWidget,
    );
    // A hint, not enforcement (Verification Model § 5) — SEND CODE stays
    // enabled and reachable.
    expect(
      tester.widget<PrimaryButton>(find.byType(PrimaryButton).first).onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'a domain the backend rejects shows its specific rejection message, '
    'not a generic failure',
    (tester) async {
      final auth = _FakeAuthService(
        startError: const WorkEmailDomainRejectedException(
          'That looks like a personal email provider — please use your '
          'work email.',
        ),
      );
      final container = _containerWith(auth);
      addTearDown(container.dispose);

      await tester.pumpWidget(_appWith(container));
      await tester.pumpAndSettle();

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'Acme Corp'); // company name
      await tester.enterText(fields.at(1), 'ada@gmail.com'); // email
      await tester.pump();
      await tester.tap(find.byType(PrimaryButton).first);
      await tester.pumpAndSettle();

      expect(
        find.text(
          'That looks like a personal email provider — please use your '
          'work email.',
        ),
        findsOneWidget,
      );
      // The optimistic-send transition (OtpEntry's own doc comment) already
      // advanced to the OTP screen before the Start call resolved — the
      // rejection surfaces there, inline, as a single OTP field with an
      // error, not by staying on the two-field entry step.
      expect(find.byType(TextField), findsOneWidget);
    },
  );

  testWidgets(
    'a correct code updates the session and profile immediately, then pops',
    (tester) async {
      final updatedSession = AuthSession(
        userId: 'user-1',
        accessToken: 'new.a.b',
        refreshToken: 'new-refresh',
        trustLevel: 3,
        isNewUser: false,
        accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
        fullName: 'Ada Lovelace',
        profilePhotoUrl: '',
      );
      final auth = _FakeAuthService(
        startResult: 60,
        verifyResult: updatedSession,
      );
      final container = _containerWith(auth);
      addTearDown(container.dispose);
      await container.read(authSessionProvider.future);

      await tester.pumpWidget(_appWith(container));
      await tester.pumpAndSettle();

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'Acme Corp'); // company name
      await tester.enterText(fields.at(1), 'ada@company.com'); // email
      await tester.pump();
      await tester.tap(find.byType(PrimaryButton).first);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '123456');
      await tester.pump();
      await tester.tap(find.byType(PrimaryButton).first);
      await tester.pumpAndSettle();

      expect(auth.verifyCallCount, 1);
      expect(auth.lastCompanyName, 'Acme Corp');
      expect(find.byType(CorporateEmailVerificationPage), findsNothing);

      final sessionState = container.read(authSessionProvider).value!;
      expect(sessionState.session!.trustLevel, 3);
      expect(sessionState.profile, isNotNull);
    },
  );
}
