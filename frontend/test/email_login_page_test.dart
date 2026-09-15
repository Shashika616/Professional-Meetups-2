import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/app_shell.dart';
import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/models/public_profile.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/storage/session_storage.dart';
import 'package:professional_connections_platform/features/auth/email_login_page.dart';
import 'package:professional_connections_platform/features/onboarding/age_confirmation_checkbox.dart';

import 'support/fake_meetup_service.dart';
import 'support/fake_secure_storage_platform.dart';

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

  _FakeAuthService({this.error, this.linkedInSession});

  final Object? error;

  /// What CONTINUE WITH LINKEDIN resolves to; null means the test does not
  /// exercise it and a tap is a bug.
  final AuthSession? linkedInSession;
  int linkedInCallCount = 0;

  /// What the last provider call carried as the 18+ attestation, so a test
  /// can prove it is the user's value and not a constant.
  bool? lastAgeConfirmedOver18;
  int startOtpCallCount = 0;
  String? lastEmail;
  String? lastCode;

  @override
  Future<int> startEmailLoginOtp(String email) async {
    startOtpCallCount++;
    return 30;
  }

  @override
  Future<AuthSession> loginWithEmail({
    required String email,
    required String code,
  }) async {
    lastEmail = email;
    lastCode = code;
    if (error != null) throw error!;
    return AuthSession(
      userId: 'user-1',
      accessToken: 'a.b.c',
      refreshToken: 'refresh-token',
      trustLevel: 0,
      isNewUser: false,
      accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
      fullName: 'Ada Lovelace',
      profilePhotoUrl: '',
    );
  }

  @override
  Future<AuthSession> signInWithLinkedIn({
    required bool ageConfirmedOver18,
  }) async {
    linkedInCallCount++;
    lastAgeConfirmedOver18 = ageConfirmedOver18;
    final session = linkedInSession;
    if (session == null) throw UnimplementedError();
    return session;
  }

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
  Future<AuthSession> linkLinkedIn() async => throw UnimplementedError();

  @override
  Future<int> startEmailSignupOtp(String email) async =>
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

Widget _appWith(AuthService authService) {
  return ProviderScope(
    overrides: [
      authServiceProvider.overrideWithValue(authService),
      sessionStorageProvider.overrideWithValue(
        SecureSessionStorage(storage: const FlutterSecureStorage()),
      ),
      meetupServiceProvider.overrideWithValue(ImmediateMeetupService()),
    ],
    child: const MaterialApp(home: EmailLoginPage()),
  );
}

AuthSession _session({required bool isNewUser}) => AuthSession(
  userId: 'user-1',
  accessToken: 'a.b.c',
  refreshToken: 'refresh-token',
  trustLevel: 1,
  isNewUser: isNewUser,
  accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
  fullName: 'Ada Lovelace',
  profilePhotoUrl: '',
);

/// Ticks the 18+ box on the method step. Every provider test must do this
/// first: the buttons are disabled until it is checked (Plan 18, Fix 2).
Future<void> _confirmAge(WidgetTester tester) async {
  await tester.tap(find.byType(Checkbox));
  await tester.pumpAndSettle();
}

/// The email form sits behind CONTINUE WITH EMAIL on the method step, and
/// that button, like the providers, is disabled until the 18+ box is
/// checked; so this confirms first.
Future<void> _openEmailForm(WidgetTester tester) async {
  await _confirmAge(tester);
  await tester.tap(find.byKey(const Key('continueWithEmail')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
  });

  testWidgets(
    'the method step offers the same one-tap providers as sign-up plus '
    'email, under a plain "Welcome back" with no explanatory paragraph',
    (tester) async {
      await tester.pumpWidget(_appWith(_FakeAuthService()));
      await tester.pumpAndSettle();

      expect(find.text('Welcome back'), findsOneWidget);
      expect(find.textContaining('Enter the email'), findsNothing);
      expect(find.text('CONTINUE WITH GOOGLE'), findsOneWidget);
      expect(find.text('CONTINUE WITH LINKEDIN'), findsOneWidget);
      expect(find.text('CONTINUE WITH APPLE'), findsNothing);
      expect(find.text('CONTINUE WITH EMAIL'), findsOneWidget);
      // The email field is not on this step; it is one tap away.
      expect(find.byType(TextFormField), findsNothing);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets('iOS shows Apple in place of Google', (tester) async {
    await tester.pumpWidget(_appWith(_FakeAuthService()));
    await tester.pumpAndSettle();

    expect(find.text('CONTINUE WITH APPLE'), findsOneWidget);
    expect(find.text('CONTINUE WITH GOOGLE'), findsNothing);
    expect(find.text('CONTINUE WITH LINKEDIN'), findsOneWidget);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('a returning member signing in with a provider goes straight to '
      'AppShell, with no profile-setup detour', (tester) async {
    final auth = _FakeAuthService(linkedInSession: _session(isNewUser: false));
    await tester.pumpWidget(_appWith(auth));
    await tester.pumpAndSettle();
    await _confirmAge(tester);

    await tester.tap(find.text('CONTINUE WITH LINKEDIN'));
    await tester.pumpAndSettle();

    expect(auth.linkedInCallCount, 1);
    expect(find.text('COMPLETE YOUR PROFILE'), findsNothing);
    expect(find.byType(AppShell), findsOneWidget);
  });

  testWidgets(
    'a provider identity the server has never seen is a new account and '
    'still gets the profile-setup screen before AppShell',
    (tester) async {
      final auth = _FakeAuthService(linkedInSession: _session(isNewUser: true));
      await tester.pumpWidget(_appWith(auth));
      await tester.pumpAndSettle();
      await _confirmAge(tester);

      await tester.tap(find.text('CONTINUE WITH LINKEDIN'));
      await tester.pumpAndSettle();

      expect(find.text('COMPLETE YOUR PROFILE'), findsOneWidget);
      expect(find.byType(AppShell), findsNothing);
    },
  );

  testWidgets(
    'the 18+ gate on sign-in is real: provider buttons do nothing until the '
    'box is checked, and the call then carries the user\'s own confirmation, '
    'never a constant (Plan 18, Fix 2)',
    (tester) async {
      final auth = _FakeAuthService(linkedInSession: _session(isNewUser: true));
      await tester.pumpWidget(_appWith(auth));
      await tester.pumpAndSettle();

      // The same sentence sign-up's age step shows, from the same widget.
      expect(find.text(AgeConfirmationCheckbox.statement), findsOneWidget);

      // Unchecked: a tap on the provider must not reach the service.
      await tester.tap(find.text('CONTINUE WITH LINKEDIN'));
      await tester.pumpAndSettle();
      expect(auth.linkedInCallCount, 0);
      expect(auth.lastAgeConfirmedOver18, isNull);
      expect(find.byType(EmailLoginPage), findsOneWidget);

      // Checked: the call goes out with the value the user gave.
      await _confirmAge(tester);
      await tester.tap(find.text('CONTINUE WITH LINKEDIN'));
      await tester.pumpAndSettle();
      expect(auth.linkedInCallCount, 1);
      expect(auth.lastAgeConfirmedOver18, isTrue);
    },
  );

  testWidgets('the 18+ box on sign-in gates CONTINUE WITH EMAIL too: one '
      'gate over every way in, so the screen never shows two locked doors '
      'and one open one', (tester) async {
    final auth = _FakeAuthService();
    await tester.pumpWidget(_appWith(auth));
    await tester.pumpAndSettle();

    // Unchecked: the email button does nothing.
    await tester.tap(find.byKey(const Key('continueWithEmail')));
    await tester.pumpAndSettle();
    expect(find.text('SEND CODE'), findsNothing);
    expect(find.text('CONTINUE WITH EMAIL'), findsOneWidget);

    // Checked: it opens the form and the OTP flow works as before.
    await _confirmAge(tester);
    await tester.tap(find.byKey(const Key('continueWithEmail')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'ada@example.com');
    await tester.pumpAndSettle();
    await tester.tap(find.text('SEND CODE'));
    await tester.pumpAndSettle();
    expect(auth.startOtpCallCount, 1);
  });

  testWidgets('back from the email form returns to the method step', (
    tester,
  ) async {
    await tester.pumpWidget(_appWith(_FakeAuthService()));
    await tester.pumpAndSettle();
    await _openEmailForm(tester);
    expect(find.text('SEND CODE'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text('CONTINUE WITH EMAIL'), findsOneWidget);
    expect(find.byType(EmailLoginPage), findsOneWidget);
  });

  testWidgets('SEND CODE is disabled until an email is entered', (
    tester,
  ) async {
    final auth = _FakeAuthService();
    await tester.pumpWidget(_appWith(auth));
    await tester.pumpAndSettle();
    await _openEmailForm(tester);

    expect(find.text('SEND CODE'), findsOneWidget);
    await tester.tap(find.text('SEND CODE'));
    await tester.pumpAndSettle();
    expect(auth.startOtpCallCount, 0);

    await tester.enterText(find.byType(TextFormField), 'ada@example.com');
    await tester.pumpAndSettle();
    await tester.tap(find.text('SEND CODE'));
    await tester.pumpAndSettle();

    expect(auth.startOtpCallCount, 1);
  });

  testWidgets(
    'full flow: email → OTP entry → loginWithEmail carries the entered '
    'code, no password anywhere (ADR-019 §1)',
    (tester) async {
      final auth = _FakeAuthService();
      await tester.pumpWidget(_appWith(auth));
      await tester.pumpAndSettle();
      await _openEmailForm(tester);

      await tester.enterText(find.byType(TextFormField), 'ada@example.com');
      await tester.pumpAndSettle();
      await tester.tap(find.text('SEND CODE'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '123456');
      await tester.pumpAndSettle();
      await tester.tap(find.text('VERIFY'));
      await tester.pumpAndSettle();

      expect(auth.lastEmail, 'ada@example.com');
      expect(auth.lastCode, '123456');
      expect(find.byType(AppShell), findsOneWidget);
    },
  );

  testWidgets('invalid credentials shows the mapped error and stays put', (
    tester,
  ) async {
    final auth = _FakeAuthService(
      error: const InvalidCredentialsException('invalid email or code'),
    );
    await tester.pumpWidget(_appWith(auth));
    await tester.pumpAndSettle();
    await _openEmailForm(tester);

    await tester.enterText(find.byType(TextFormField), 'ada@example.com');
    await tester.pumpAndSettle();
    await tester.tap(find.text('SEND CODE'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '000000');
    await tester.pumpAndSettle();
    await tester.tap(find.text('VERIFY'));
    await tester.pumpAndSettle();

    expect(find.text('invalid email or code'), findsOneWidget);
    expect(find.byType(EmailLoginPage), findsOneWidget);
    expect(find.byType(AppShell), findsNothing);
  });
}
