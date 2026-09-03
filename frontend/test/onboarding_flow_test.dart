import 'dart:async';

import 'package:flutter/foundation.dart';
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
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/storage/session_storage.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/onboarding/onboarding_flow.dart';

import 'support/fake_meetup_service.dart';
import 'support/fake_secure_storage_platform.dart';

class _FakeAuthService implements AuthService {
  _FakeAuthService.success(AuthSession session, {UserProfile? profile})
    : _session = session,
      _error = null,
      _completer = null,
      // Keeping the call-site-facing `profile:` name (vs. `_profile:`) is
      // worth the extra assignment line.
      // ignore: prefer_initializing_formals
      _profile = profile;

  _FakeAuthService.failure(Object error)
    : _session = null,
      _error = error,
      _completer = null,
      _profile = null;

  _FakeAuthService.pending()
    : _session = null,
      _error = null,
      _completer = Completer<AuthSession>(),
      _profile = null;

  final AuthSession? _session;
  final Object? _error;
  final Completer<AuthSession>? _completer;
  final UserProfile? _profile;
  int callCount = 0;

  @override
  Future<AuthSession> signInWithLinkedIn({
    required bool ageConfirmedOver18,
  }) async {
    callCount++;
    if (_completer != null) return _completer.future;
    if (_error != null) throw _error;
    return _session!;
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
  }) async => UserProfile(id: 'user-1', fullName: fullName, trustLevel: 1);

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

  // authSessionProvider swallows a getProfile() failure and falls back to
  // the session-derived profile (app_providers.dart), so throwing when no
  // _profile was supplied doesn't break sign-in for tests that don't care
  // about profile contents — only the returning-user tests need a real one.
  @override
  Future<UserProfile> getProfile() async =>
      _profile ?? (throw UnimplementedError());

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

final _testSession = AuthSession(
  userId: 'user-1',
  accessToken: 'a.b.c',
  refreshToken: 'refresh-token',
  trustLevel: 1,
  isNewUser: true,
  accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
  fullName: 'Ada Lovelace',
  profilePhotoUrl: '',
);

/// Checks the age-confirmation box and taps CONTINUE — every test starts
/// here now (ADR-014: the age gate is shown first, before any signup
/// option is even visible).
Future<void> _confirmAge(WidgetTester tester) async {
  await tester.tap(find.byType(Checkbox));
  await tester.pumpAndSettle();
  await tester.tap(find.text('CONTINUE'));
  await tester.pumpAndSettle();
}

/// Taps CONTINUE on ADR-019 §2's post-auth profile-setup screen — every
/// success path lands here, right after auth succeeds, before AppShell;
/// it's the only screen initial onboarding shows now. Full name is
/// pre-filled from the session, so CONTINUE is already enabled with no
/// typing needed; company fields are left blank (optional).
Future<void> _completeProfileSetup(WidgetTester tester) async {
  expect(find.text('COMPLETE YOUR PROFILE'), findsOneWidget);
  await tester.tap(find.text('CONTINUE'));
  await tester.pumpAndSettle();
}

Widget _appWith(AuthService authService) {
  return ProviderScope(
    overrides: [
      authServiceProvider.overrideWithValue(authService),
      sessionStorageProvider.overrideWithValue(
        SecureSessionStorage(storage: const FlutterSecureStorage()),
      ),
      // Success path lands on AppShell, whose HomePage reads
      // myMeetupsProvider (backed by this) — without an override it
      // defaults to the real HttpMeetupService and attempts a live
      // network call.
      meetupServiceProvider.overrideWithValue(ImmediateMeetupService()),
    ],
    child: const MaterialApp(home: OnboardingFlow()),
  );
}

void main() {
  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
  });

  testWidgets(
    'success path goes straight from LinkedIn sign-in to the profile-setup '
    'screen, then AppShell — no Level 2/3 verification screens shown',
    (tester) async {
      await tester.pumpWidget(_appWith(_FakeAuthService.success(_testSession)));
      await tester.pumpAndSettle();
      await _confirmAge(tester);

      await tester.tap(find.text('CONTINUE WITH LINKEDIN'));
      await tester.pumpAndSettle();

      // Straight to the mandatory profile-setup screen — not AppShell yet,
      // and none of the phone/personal-email/personal-details/corporate-
      // email screens are shown at all during initial onboarding anymore.
      expect(find.text('COMPLETE YOUR PROFILE'), findsOneWidget);
      expect(find.text('Verify Your Phone'), findsNothing);
      expect(find.byType(AppShell), findsNothing);

      await _completeProfileSetup(tester);

      expect(find.byType(AppShell), findsOneWidget);
      expect(find.byType(OnboardingFlow), findsNothing);
    },
  );

  testWidgets(
    'a returning user with pending Level 2/3 steps still only sees the '
    'profile-setup screen — those steps are reachable later from Profile, '
    'not shown during onboarding',
    (tester) async {
      final auth = _FakeAuthService.success(
        _testSession,
        profile: const UserProfile(
          id: 'user-1',
          fullName: 'Ada Lovelace',
          trustLevel: 1,
          // Nothing verified yet — used to mean the full four-step
          // sequence would run; now it's irrelevant to onboarding.
        ),
      );
      await tester.pumpWidget(_appWith(auth));
      await tester.pumpAndSettle();
      await _confirmAge(tester);

      await tester.tap(find.text('CONTINUE WITH LINKEDIN'));
      await tester.pumpAndSettle();

      expect(find.text('Verify Your Phone'), findsNothing);
      await _completeProfileSetup(tester);
      expect(find.byType(AppShell), findsOneWidget);
      expect(find.byType(OnboardingFlow), findsNothing);
    },
  );

  testWidgets('a returning user who already verified a company skips the '
      'profile-setup screen entirely — it must not re-ask for information '
      'already on file, only shown once per account, not once per sign-in', (
    tester,
  ) async {
    final auth = _FakeAuthService.success(
      _testSession,
      profile: const UserProfile(
        id: 'user-1',
        fullName: 'Ada Lovelace',
        trustLevel: 1,
        companyDomain: 'acmecorp.com',
        workEmailVerified: true,
      ),
    );
    await tester.pumpWidget(_appWith(auth));
    await tester.pumpAndSettle();
    await _confirmAge(tester);

    await tester.tap(find.text('CONTINUE WITH LINKEDIN'));
    await tester.pumpAndSettle();

    expect(find.text('COMPLETE YOUR PROFILE'), findsNothing);
    expect(find.byType(AppShell), findsOneWidget);
    expect(find.byType(OnboardingFlow), findsNothing);
  });

  testWidgets(
    'the profile-setup screen is skippable — Skip for now lands directly '
    'on AppShell without saving anything',
    (tester) async {
      final auth = _FakeAuthService.success(_testSession);
      await tester.pumpWidget(_appWith(auth));
      await tester.pumpAndSettle();
      await _confirmAge(tester);

      await tester.tap(find.text('CONTINUE WITH LINKEDIN'));
      await tester.pumpAndSettle();

      expect(find.text('COMPLETE YOUR PROFILE'), findsOneWidget);
      await tester.tap(find.text('Skip for now'));
      await tester.pumpAndSettle();

      expect(find.byType(AppShell), findsOneWidget);
      expect(find.byType(OnboardingFlow), findsNothing);
    },
  );

  testWidgets('failure path shows the mapped error and stays put', (
    tester,
  ) async {
    final auth = _FakeAuthService.failure(
      const InvalidGrantException('linkedin rejected the code'),
    );
    await tester.pumpWidget(_appWith(auth));
    await tester.pumpAndSettle();
    await _confirmAge(tester);

    await tester.tap(find.text('CONTINUE WITH LINKEDIN'));
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingFlow), findsOneWidget);
    expect(find.byType(AppShell), findsNothing);
    expect(find.text('linkedin rejected the code'), findsOneWidget);
  });

  testWidgets('age confirmation is shown before any signup option', (
    tester,
  ) async {
    await tester.pumpWidget(_appWith(_FakeAuthService.success(_testSession)));
    await tester.pumpAndSettle();

    expect(
      find.text('I confirm I am 18 years of age or older.'),
      findsOneWidget,
    );
    expect(find.text('CONTINUE WITH LINKEDIN'), findsNothing);

    // CONTINUE is disabled until the box is checked.
    await tester.tap(find.text('CONTINUE'));
    await tester.pumpAndSettle();
    expect(
      find.text('I confirm I am 18 years of age or older.'),
      findsOneWidget,
    );

    await _confirmAge(tester);
    expect(find.text('CONTINUE WITH LINKEDIN'), findsOneWidget);
  });

  testWidgets('ADR-014 microcopy renders on the choose-method step', (
    tester,
  ) async {
    await tester.pumpWidget(_appWith(_FakeAuthService.success(_testSession)));
    await tester.pumpAndSettle();
    await _confirmAge(tester);

    expect(
      find.textContaining('keeps your account more restricted'),
      findsOneWidget,
    );
    expect(find.text('Sign up with email'), findsOneWidget);
  });

  testWidgets(
    'loading state disables the button so a slow tap cannot double-fire',
    (tester) async {
      final auth = _FakeAuthService.pending();
      await tester.pumpWidget(_appWith(auth));
      await tester.pumpAndSettle();
      await _confirmAge(tester);

      // A stable Key, not find.text(...) — PrimaryButton swaps its label
      // for a spinner once isLoading is true, so a text-based finder would
      // find nothing for the second tap below.
      final button = find.byKey(const Key('continueWithLinkedIn'));

      await tester.tap(button);
      await tester.pump(); // enters the loading state; never settles, the
      // fake's Future is intentionally never completed.

      // A second tap while still loading must not invoke signInWithLinkedIn
      // again — PrimaryButton disables its own tap handler while loading.
      await tester.tap(button);
      await tester.pump();

      expect(auth.callCount, 1);
    },
  );

  group('Apple Guideline 4.8 — equal visual weight on iOS', () {
    testWidgets(
      'CONTINUE WITH APPLE and CONTINUE WITH LINKEDIN render at the same '
      'size — a real layout assertion, not just "looks right"',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

        await tester.pumpWidget(
          _appWith(_FakeAuthService.success(_testSession)),
        );
        await tester.pumpAndSettle();
        await _confirmAge(tester);

        expect(find.text('CONTINUE WITH APPLE'), findsOneWidget);
        expect(find.text('CONTINUE WITH LINKEDIN'), findsOneWidget);

        final appleSize = tester.getSize(
          find.ancestor(
            of: find.text('CONTINUE WITH APPLE'),
            matching: find.byType(PrimaryButton),
          ),
        );
        final linkedInSize = tester.getSize(
          find.byKey(const Key('continueWithLinkedIn')),
        );

        // Reset before the test body returns — the framework asserts every
        // debug var is back to its default as soon as the test body
        // completes, before any addTearDown callback would run.
        debugDefaultTargetPlatformOverride = null;

        expect(appleSize, linkedInSize);
      },
    );
  });
}
