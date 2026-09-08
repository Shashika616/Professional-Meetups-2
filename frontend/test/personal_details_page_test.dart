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
import 'package:professional_connections_platform/features/verification/personal_details_page.dart';

import 'support/fake_secure_storage_platform.dart';

class _FakeAuthService implements AuthService {
  // ADR-002 § 3. Unused by this test — every fake in test/ implements the
  // full AuthService surface, so a new method lands here even when the test
  // never calls it.
  @override
  Future<AuthSession> guestSignup({required bool ageConfirmedOver18}) =>
      throw UnimplementedError();

  _FakeAuthService({this.submitResult, this.submitError});

  final AuthSession? submitResult;
  final Object? submitError;
  int submitCallCount = 0;
  String? lastLegalName;
  String? lastAddress;

  @override
  Future<AuthSession> submitPersonalDetails(
    String legalName,
    String address,
  ) async {
    submitCallCount++;
    lastLegalName = legalName;
    lastAddress = address;
    if (submitError != null) throw submitError!;
    return submitResult!;
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

Widget _appWith(ProviderContainer container, {UserProfile? profile}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Navigator(
        onGenerateRoute: (settings) => MaterialPageRoute(
          builder: (context) => PersonalDetailsPage(profile: profile),
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
    'Skip pops the screen without ever calling submitPersonalDetails',
    (tester) async {
      final auth = _FakeAuthService();
      final container = _containerWith(auth);
      addTearDown(container.dispose);

      await tester.pumpWidget(_appWith(container));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Skip for now'));
      await tester.pumpAndSettle();

      expect(find.byType(PersonalDetailsPage), findsNothing);
      expect(auth.submitCallCount, 0);
    },
  );

  testWidgets('CONTINUE stays disabled until legal name is filled (address '
      'removed entirely, ADR-023 §1/§2)', (tester) async {
    final auth = _FakeAuthService();
    final container = _containerWith(auth);
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    // Exactly one text field now — address's GlassTextField is gone, not
    // just relegated to optional.
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed,
      isNull,
    );

    await tester.enterText(find.byType(TextField), 'Ada Lovelace');
    await tester.pump();
    expect(
      tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets('a submit failure shows the mapped error and stays on this '
      'screen', (tester) async {
    final auth = _FakeAuthService(
      submitError: const AuthNetworkException('Something went wrong.'),
    );
    final container = _containerWith(auth);
    addTearDown(container.dispose);

    await tester.pumpWidget(_appWith(container));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Ada Lovelace');
    await tester.pump();
    await tester.tap(find.byType(PrimaryButton));
    await tester.pump();
    await tester.pump();

    expect(find.text('Something went wrong.'), findsOneWidget);
    expect(find.byType(PersonalDetailsPage), findsOneWidget);
  });

  testWidgets(
    'a successful submit updates the session and profile immediately, '
    'sending an empty address, then pops',
    (tester) async {
      final updatedSession = AuthSession(
        userId: 'user-1',
        accessToken: 'new.a.b',
        refreshToken: 'new-refresh',
        trustLevel: 2,
        isNewUser: false,
        accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
        fullName: 'Ada Lovelace',
        profilePhotoUrl: '',
      );
      final auth = _FakeAuthService(submitResult: updatedSession);
      final container = _containerWith(auth);
      addTearDown(container.dispose);
      await container.read(authSessionProvider.future);

      await tester.pumpWidget(_appWith(container));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Ada Lovelace');
      await tester.pump();
      await tester.tap(find.byType(PrimaryButton));
      await tester.pumpAndSettle();

      expect(auth.submitCallCount, 1);
      expect(auth.lastLegalName, 'Ada Lovelace');
      expect(auth.lastAddress, '');
      expect(find.byType(PersonalDetailsPage), findsNothing);

      final sessionState = container.read(authSessionProvider).value!;
      expect(sessionState.session!.accessToken, 'new.a.b');
      expect(sessionState.profile, isNotNull);
    },
  );

  testWidgets(
    'pre-fills the legal-name field from fullName when personal details '
    'are not yet complete (ADR-023 §3)',
    (tester) async {
      final auth = _FakeAuthService();
      final container = _containerWith(auth);
      addTearDown(container.dispose);

      const profile = UserProfile(
        id: 'user-1',
        fullName: 'Ada Lovelace',
        personalDetailsComplete: false,
        legalName: '',
      );

      await tester.pumpWidget(_appWith(container, profile: profile));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Ada Lovelace',
      );
    },
  );

  testWidgets(
    'pre-fills the legal-name field from the real legalName once personal '
    'details are already complete, not from fullName again (ADR-023 §3)',
    (tester) async {
      final auth = _FakeAuthService();
      final container = _containerWith(auth);
      addTearDown(container.dispose);

      const profile = UserProfile(
        id: 'user-1',
        fullName: 'Ada Lovelace',
        personalDetailsComplete: true,
        legalName: 'Augusta Ada King',
      );

      await tester.pumpWidget(_appWith(container, profile: profile));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Augusta Ada King',
      );
    },
  );
}
