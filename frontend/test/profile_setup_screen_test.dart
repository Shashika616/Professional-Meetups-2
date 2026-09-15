import 'package:flutter/material.dart';
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
import 'package:professional_connections_platform/core/storage/session_storage.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/onboarding/profile_setup_screen.dart';

import 'support/fake_secure_storage_platform.dart';

/// ADR-019 §2's new mandatory post-auth screen — this suite covers the
/// three things the backend/frontend plans call out explicitly as
/// easy-to-accidentally-over-gate: CONTINUE enables on full name alone,
/// the company email field stays disabled until a company name is
/// entered, and a domain-mismatch rejection renders the backend's exact
/// message, not a generic fallback.
class _FakeAuthService implements AuthService {
  @override
  Future<PublicProfile> getPublicProfile(String userId) =>
      throw UnimplementedError('not exercised by this test');

  // ADR-002 § 3. Unused by this test — every fake in test/ implements the
  // full AuthService surface, so a new method lands here even when the test
  // never calls it.
  @override
  Future<AuthSession> guestSignup({required bool ageConfirmedOver18}) =>
      throw UnimplementedError();

  _FakeAuthService({this.verifyError});

  final Object? verifyError;
  int startCorporateCallCount = 0;
  String? lastCompleteProfileFullName;

  @override
  Future<int> startCorporateEmailVerification(String email) async {
    startCorporateCallCount++;
    return 60;
  }

  @override
  Future<AuthSession> verifyCorporateEmailCode(
    String email,
    String code,
    String companyName,
  ) async {
    if (verifyError != null) throw verifyError!;
    throw UnimplementedError(); // no test needs a successful verify here
  }

  @override
  Future<UserProfile> completeProfileSetup({
    required String fullName,
    String? companyName,
    String? companyEmail,
  }) async {
    lastCompleteProfileFullName = fullName;
    return UserProfile(id: 'user-1', fullName: fullName, trustLevel: 1);
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
  Future<int> startEmailLoginOtp(String email) async =>
      throw UnimplementedError();

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
  Future<AuthSession> refreshSession(String refreshToken) async =>
      throw UnimplementedError();

  @override
  Future<void> logout(
    String refreshToken, {
    String? accessToken,
    String? fcmToken,
  }) async {}

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
  Future<UserProfile> getProfile() async =>
      const UserProfile(id: 'user-1', fullName: 'Ada Lovelace');

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

Widget _appWith(ProviderContainer container, {String initialFullName = ''}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Navigator(
        onGenerateRoute: (settings) => MaterialPageRoute(
          builder: (context) =>
              ProfileSetupScreen(initialFullName: initialFullName),
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

  testWidgets(
    'CONTINUE is disabled with an empty name, and enables with only a full '
    'name entered — company fields untouched',
    (tester) async {
      final auth = _FakeAuthService();
      final container = _containerWith(auth);
      addTearDown(container.dispose);
      await container.read(authSessionProvider.future);

      await tester.pumpWidget(_appWith(container));
      await tester.pumpAndSettle();

      final continueButton = find.widgetWithText(PrimaryButton, 'CONTINUE');
      expect(tester.widget<PrimaryButton>(continueButton).onPressed, isNull);

      await tester.enterText(find.byType(TextField).first, 'Ada Lovelace');
      await tester.pumpAndSettle();

      expect(tester.widget<PrimaryButton>(continueButton).onPressed, isNotNull);

      await tester.tap(continueButton);
      await tester.pumpAndSettle();

      expect(auth.lastCompleteProfileFullName, 'Ada Lovelace');
      expect(find.byType(ProfileSetupScreen), findsNothing);
    },
  );

  testWidgets(
    'company email field stays disabled until a company name is entered',
    (tester) async {
      final auth = _FakeAuthService();
      final container = _containerWith(auth);
      addTearDown(container.dispose);
      await container.read(authSessionProvider.future);

      await tester.pumpWidget(_appWith(container));
      await tester.pumpAndSettle();

      final fields = find.byType(TextField);
      // Field order: full name, company name, company email.
      expect(tester.widget<TextField>(fields.at(2)).enabled, isFalse);

      await tester.enterText(fields.at(1), 'Acme Corp');
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(fields.at(2)).enabled, isTrue);
    },
  );

  testWidgets(
    "a domain-mismatch rejection renders the backend's exact message, not "
    'a generic fallback',
    (tester) async {
      final auth = _FakeAuthService(
        verifyError: const InvalidVerificationCodeException(
          'the email domain does not match the company name entered — '
          'please check both and try again',
        ),
      );
      final container = _containerWith(auth);
      addTearDown(container.dispose);
      await container.read(authSessionProvider.future);

      await tester.pumpWidget(_appWith(container));
      await tester.pumpAndSettle();

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(1), 'Acme Corp');
      await tester.pumpAndSettle();
      await tester.enterText(fields.at(2), 'ada@acme-lookalike.net');
      await tester.pumpAndSettle();

      // The SecondaryButton "VERIFY" next to the company-email field —
      // the only "VERIFY" text on screen before OtpEntry appears.
      await tester.tap(find.text('VERIFY').first);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, '123456');
      await tester.pump();
      await tester.tap(find.widgetWithText(PrimaryButton, 'VERIFY'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'the email domain does not match the company name entered — '
          'please check both and try again',
        ),
        findsOneWidget,
      );
      expect(auth.startCorporateCallCount, 1);
    },
  );
}
