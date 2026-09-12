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
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

import 'support/fake_secure_storage_platform.dart';

/// A configurable fake covering exactly what `VerificationChecklistPage`
/// and the three verification pages it pushes (Phone/PersonalEmail/
/// PersonalDetails) need — [phoneVerified]/[personalEmailVerified]/
/// [personalDetailsComplete]/[linkedInConnected] are mutable so
/// `verifyPhoneCode` etc. can flip them, then [getProfile] (re-fetched by
/// `authSessionProvider.notifier.completeVerification` on every successful
/// verify) reflects the new state — the same reactive path the real app
/// uses, not a shortcut around it.
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

  _FakeAuthService({this.linkedInConnected = true});

  bool linkedInConnected;

  /// Lets a test model the ADR-002 state that LinkedIn-derivation cannot
  /// express: trust level 1 with no LinkedIn. Null means "derive from
  /// [linkedInConnected]", which is what every pre-existing test wants.
  int? trustLevelOverride;
  bool phoneVerified = false;
  bool personalEmailVerified = false;
  bool personalDetailsComplete = false;

  int verifyPhoneCallCount = 0;
  int verifyPersonalEmailCallCount = 0;
  int submitPersonalDetailsCallCount = 0;

  @override
  Future<UserProfile> getProfile() async => UserProfile(
    id: 'user-1',
    fullName: 'Ada Lovelace',
    // ADR-002 §2 decoupled these two. trustLevel 1 now means "completed any
    // real signup path", which is true whether or not LinkedIn is involved;
    // linkedInConnectedFlag is the server's own answer to the LinkedIn
    // question and is what the page reads. Setting only trustLevel here (as
    // this fake used to) modelled a server that no longer exists.
    trustLevel: trustLevelOverride ?? (linkedInConnected ? 1 : 0),
    linkedInConnectedFlag: linkedInConnected,
    phoneVerified: phoneVerified,
    personalEmailVerified: personalEmailVerified,
    personalDetailsComplete: personalDetailsComplete,
  );

  @override
  Future<int> startPhoneVerification(String phoneNumber) async => 60;

  @override
  Future<AuthSession> verifyPhoneCode(String phoneNumber, String code) async {
    verifyPhoneCallCount++;
    phoneVerified = true;
    return _session;
  }

  @override
  Future<int> startPersonalEmailVerification(String email) async => 60;

  @override
  Future<AuthSession> verifyPersonalEmailCode(String email, String code) async {
    verifyPersonalEmailCallCount++;
    personalEmailVerified = true;
    return _session;
  }

  @override
  Future<AuthSession> submitPersonalDetails(
    String legalName,
    String address,
  ) async {
    submitPersonalDetailsCallCount++;
    personalDetailsComplete = true;
    return _session;
  }

  @override
  Future<AuthSession> linkLinkedIn() async {
    linkedInConnected = true;
    return _session;
  }

  static final _session = AuthSession(
    userId: 'user-1',
    accessToken: 'a.b.c',
    refreshToken: 'refresh-token-abc',
    trustLevel: 1,
    isNewUser: false,
    accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
    fullName: 'Ada Lovelace',
    profilePhotoUrl: '',
  );

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

final _testSession = AuthSession(
  userId: 'user-1',
  accessToken: 'a.b.c',
  refreshToken: 'refresh-token-abc',
  trustLevel: 1,
  isNewUser: false,
  accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
  fullName: 'Ada Lovelace',
  profilePhotoUrl: '',
);

Widget _appWith(AuthService authService) {
  return ProviderScope(
    overrides: [
      authServiceProvider.overrideWithValue(authService),
      sessionStorageProvider.overrideWithValue(
        SecureSessionStorage(storage: const FlutterSecureStorage()),
      ),
    ],
    child: const MaterialApp(home: VerificationChecklistPage()),
  );
}

void main() {
  setUp(() async {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
    await SecureSessionStorage(
      storage: const FlutterSecureStorage(),
    ).saveSession(_testSession);
  });

  testWidgets('shows all three rows (LinkedIn already connected) as not-done '
      'initially, with COMPLETE disabled, and never shows a corporate/'
      'work-email row', (tester) async {
    final auth = _FakeAuthService();
    await tester.pumpWidget(_appWith(auth));
    await tester.pumpAndSettle();

    expect(find.text('Not verified'), findsNWidgets(3));
    expect(find.text('Work Email'), findsNothing);
    expect(find.text('Corporate Email'), findsNothing);

    final complete = tester.widget<PrimaryButton>(
      find.widgetWithText(PrimaryButton, 'COMPLETE'),
    );
    expect(complete.onPressed, isNull);
  });

  testWidgets(
    'round-7 hardening: renders AppBackground, so the page is actually '
    'theme-reactive instead of falling through to plain black — a pure '
    'rendering-structure check, not new logic',
    (tester) async {
      final auth = _FakeAuthService();
      await tester.pumpWidget(_appWith(auth));
      await tester.pumpAndSettle();

      expect(find.byType(AppBackground), findsOneWidget);
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.extendBodyBehindAppBar, isTrue);
    },
  );

  testWidgets(
    'a Level-0 (LinkedIn not connected) viewer sees the Connect LinkedIn '
    'banner; the other three rows stay locked behind it',
    (tester) async {
      final auth = _FakeAuthService(linkedInConnected: false);
      await tester.pumpWidget(_appWith(auth));
      await tester.pumpAndSettle();

      expect(find.text('Connect LinkedIn'), findsOneWidget);
      expect(find.text('Connect LinkedIn first'), findsNWidgets(3));
    },
  );

  // ADR-002 § 2 CREATED A STATE THAT DID NOT EXIST BEFORE: trust level 1
  // WITHOUT LinkedIn. Under the old ladder Level 1 was reachable only via
  // LinkedIn, so `linkedInConnected` was derived as `trustLevel >= 1` — an
  // inference that is now simply wrong for every Apple/Google/email account.
  //
  // Left unfixed it would have shown this page's LinkedIn row as done and
  // unlocked the three rows beneath it, each of which the server then
  // rejects (requireLinkedIn, unchanged by ADR-002). The user would have
  // seen a checklist telling them to do things that immediately 403.
  //
  // This is the regression test for that. §D of the plan asks for this page
  // to be exercised from a Level 0 AND a Level 1 email-only account; the
  // test above is the Level 0 half, this is the Level 1 half.
  testWidgets(
    'a Level-1 email-only viewer (no LinkedIn) is still told to connect '
    'LinkedIn — trust level 1 no longer implies LinkedIn (ADR-002 § 2)',
    (tester) async {
      final auth = _FakeAuthService(linkedInConnected: false)
        // The distinguishing state: a real signup path was completed, so the
        // account is Level 1, but LinkedIn was not one of them.
        ..trustLevelOverride = 1;
      await tester.pumpWidget(_appWith(auth));
      await tester.pumpAndSettle();

      expect(
        find.text('Connect LinkedIn'),
        findsOneWidget,
        reason:
            'a Level 1 account with no LinkedIn was treated as already '
            'connected — the page would unlock rows the server rejects',
      );
      expect(find.text('Connect LinkedIn first'), findsNWidgets(3));
    },
  );

  testWidgets(
    'verifying phone, personal email, and personal details in turn flips '
    'each row to done and enables COMPLETE once all four (LinkedIn '
    'already connected) are done — driven through the real pushed '
    'verification pages, not asserted directly',
    (tester) async {
      final auth = _FakeAuthService();
      await tester.pumpWidget(_appWith(auth));
      await tester.pumpAndSettle();

      // --- Phone ---
      await tester.tap(find.text('Phone'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '712345678');
      await tester.pump();
      await tester.tap(find.byType(PrimaryButton).first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '000000');
      await tester.pump();
      await tester.tap(find.byType(PrimaryButton).first);
      await tester.pumpAndSettle();

      expect(auth.verifyPhoneCallCount, 1);
      expect(find.byType(VerificationChecklistPage), findsOneWidget);
      expect(find.text('Not verified'), findsNWidgets(2));

      // --- Personal Email ---
      await tester.tap(find.text('Personal Email'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'ada@example.com');
      await tester.pump();
      await tester.tap(find.byType(PrimaryButton).first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '000000');
      await tester.pump();
      await tester.tap(find.byType(PrimaryButton).first);
      await tester.pumpAndSettle();

      expect(auth.verifyPersonalEmailCallCount, 1);
      expect(find.text('Not verified'), findsOneWidget);

      // COMPLETE still disabled — Personal Details remains.
      var complete = tester.widget<PrimaryButton>(
        find.widgetWithText(PrimaryButton, 'COMPLETE'),
      );
      expect(complete.onPressed, isNull);

      // --- Personal Details ---
      await tester.tap(find.text('Personal Details'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Ada Lovelace');
      await tester.pump();
      await tester.tap(find.byType(PrimaryButton));
      await tester.pumpAndSettle();

      expect(auth.submitPersonalDetailsCallCount, 1);
      expect(find.text('Not verified'), findsNothing);
      expect(find.text('Verified'), findsNWidgets(3));

      complete = tester.widget<PrimaryButton>(
        find.widgetWithText(PrimaryButton, 'COMPLETE'),
      );
      expect(complete.onPressed, isNotNull);

      // Tapping COMPLETE pops back — it does not retry any join action
      // (there's nothing to retry from this page in isolation).
      await tester.tap(find.text('COMPLETE'));
      await tester.pumpAndSettle();
      expect(find.byType(VerificationChecklistPage), findsNothing);
    },
  );
}
