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
import 'package:professional_connections_platform/features/verification/hosting_unlock_page.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

import 'support/fake_secure_storage_platform.dart';

/// Models the Level 2 → 3 states this page has to distinguish (ADR-002 § 4).
/// Level 2 is satisfied by default because that is this page's normal
/// precondition — it is reached by a user who can already join meetups.
class _FakeAuthService implements AuthService {
  _FakeAuthService({
    this.levelTwoDone = true,
    this.companyName = '',
    this.workEmailVerified = false,
  });

  final bool levelTwoDone;
  final String companyName;
  final bool workEmailVerified;

  @override
  Future<UserProfile> getProfile() async => UserProfile(
    id: 'user-1',
    fullName: 'Ada Lovelace',
    trustLevel: workEmailVerified && companyName.isNotEmpty
        ? 3
        : levelTwoDone
        ? 2
        : 1,
    linkedInConnectedFlag: levelTwoDone,
    phoneVerified: levelTwoDone,
    personalEmailVerified: levelTwoDone,
    personalDetailsComplete: levelTwoDone,
    companyName: companyName,
    workEmailVerified: workEmailVerified,
  );

  // Everything below is unused by this page — it pushes
  // CorporateEmailVerificationPage rather than doing any verification
  // itself, which is the point (ADR-002 § 6: reuse the existing widget, do
  // not invent new verification logic).
  @override
  Future<AuthSession> guestSignup({required bool ageConfirmedOver18}) =>
      throw UnimplementedError();
  @override
  Future<AuthSession> signInWithLinkedIn({required bool ageConfirmedOver18}) =>
      throw UnimplementedError();
  @override
  Future<AuthSession> signInWithApple({required bool ageConfirmedOver18}) =>
      throw UnimplementedError();
  @override
  Future<AuthSession> signInWithGoogle({required bool ageConfirmedOver18}) =>
      throw UnimplementedError();
  @override
  Future<AuthSession> signUpWithEmail({
    required String email,
    required String code,
    required bool ageConfirmedOver18,
  }) => throw UnimplementedError();
  @override
  Future<AuthSession> loginWithEmail({
    required String email,
    required String code,
  }) => throw UnimplementedError();
  @override
  Future<AuthSession> linkLinkedIn() => throw UnimplementedError();
  @override
  Future<int> startEmailSignupOtp(String email) => throw UnimplementedError();
  @override
  Future<int> startEmailLoginOtp(String email) => throw UnimplementedError();
  @override
  Future<AuthSession> refreshSession(String refreshToken) =>
      throw UnimplementedError();
  @override
  Future<void> logout(String refreshToken) => throw UnimplementedError();
  @override
  Future<int> startPhoneVerification(String phoneNumber) =>
      throw UnimplementedError();
  @override
  Future<AuthSession> verifyPhoneCode(String phoneNumber, String code) =>
      throw UnimplementedError();
  @override
  Future<int> startPersonalEmailVerification(String email) =>
      throw UnimplementedError();
  @override
  Future<AuthSession> verifyPersonalEmailCode(String email, String code) =>
      throw UnimplementedError();
  @override
  Future<AuthSession> submitPersonalDetails(String legalName, String address) =>
      throw UnimplementedError();
  @override
  Future<int> startCorporateEmailVerification(String email) async => 60;
  @override
  Future<AuthSession> verifyCorporateEmailCode(
    String email,
    String code,
    String companyName,
  ) => throw UnimplementedError();
  @override
  Future<UserProfile> completeProfileSetup({
    required String fullName,
    String? companyName,
    String? companyEmail,
  }) => throw UnimplementedError();
  @override
  Future<TrustedContact> addTrustedContact({
    required String name,
    String phoneNumber = '',
    String email = '',
  }) => throw UnimplementedError();
  @override
  Future<List<TrustedContact>> listTrustedContacts() =>
      throw UnimplementedError();
  @override
  Future<void> removeTrustedContact(String contactId) =>
      throw UnimplementedError();
  @override
  Future<int> triggerSos({
    required String contextMessage,
    required double latitude,
    required double longitude,
  }) => throw UnimplementedError();
  @override
  Future<void> updateLastKnownLocation({
    required double latitude,
    required double longitude,
  }) => throw UnimplementedError();
}

final _testSession = AuthSession(
  userId: 'user-1',
  accessToken: 'a.b.c',
  refreshToken: 'refresh-token-abc',
  trustLevel: 2,
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
    child: const MaterialApp(home: HostingUnlockPage()),
  );
}

/// COMPLETE is a [PrimaryButton]; a null onPressed is what "disabled" means.
bool _completeEnabled(WidgetTester tester) {
  final button = tester.widget<PrimaryButton>(
    find.byKey(const Key('hostingUnlockComplete')),
  );
  return button.onPressed != null;
}

void main() {
  setUp(() async {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
    await SecureSessionStorage(
      storage: const FlutterSecureStorage(),
    ).saveSession(_testSession);
  });

  testWidgets('shows both new rows as not-done, with COMPLETE disabled', (
    tester,
  ) async {
    await tester.pumpWidget(_appWith(_FakeAuthService()));
    await tester.pumpAndSettle();

    expect(find.text('UNLOCK HOSTING MEETUPS'), findsOneWidget);
    expect(
      find.byKey(const Key('hostingUnlockCompanyNameRow')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('hostingUnlockCompanyEmailRow')),
      findsOneWidget,
    );
    expect(find.text('Not added'), findsOneWidget);
    expect(find.text('Not verified'), findsOneWidget);
    expect(_completeEnabled(tester), isFalse);
  });

  // The gating requirement from § E. One test per case rather than a loop:
  // each combination gets its own fresh widget tree, so a failure names the
  // exact combination rather than a loop iteration.
  //
  // Getting this wrong in the permissive direction would enable COMPLETE for
  // a user the server will still refuse to let host.
  testWidgets('COMPLETE stays disabled with neither', (tester) async {
    await tester.pumpWidget(_appWith(_FakeAuthService()));
    await tester.pumpAndSettle();
    expect(_completeEnabled(tester), isFalse);
  });

  testWidgets('COMPLETE stays disabled with the company name alone', (
    tester,
  ) async {
    await tester.pumpWidget(_appWith(_FakeAuthService(companyName: 'Acme')));
    await tester.pumpAndSettle();
    expect(
      _completeEnabled(tester),
      isFalse,
      reason: 'a name with no verified work email does not reach Level 3',
    );
  });

  testWidgets('COMPLETE stays disabled with the verified email alone', (
    tester,
  ) async {
    await tester.pumpWidget(
      _appWith(_FakeAuthService(workEmailVerified: true)),
    );
    await tester.pumpAndSettle();
    expect(
      _completeEnabled(tester),
      isFalse,
      reason:
          'a verified work email with no company name does not reach Level 3 '
          '— this is the half ADR-002 § 2 newly added',
    );
  });

  testWidgets('COMPLETE is enabled once both are done', (tester) async {
    await tester.pumpWidget(
      _appWith(_FakeAuthService(companyName: 'Acme', workEmailVerified: true)),
    );
    await tester.pumpAndSettle();
    expect(_completeEnabled(tester), isTrue);
  });

  testWidgets('a completed company name is shown back to the user', (
    tester,
  ) async {
    await tester.pumpWidget(
      _appWith(
        _FakeAuthService(
          companyName: 'Acme Corporation',
          workEmailVerified: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The row's subtitle is the organisation itself, not a generic "Done" —
    // it is the one place a user can check what was actually recorded.
    expect(find.text('Acme Corporation'), findsOneWidget);
    expect(find.text('Verified'), findsOneWidget);
  });

  // ADR-002 § 6 is explicit that this flow reuses the existing widget rather
  // than introducing new verification logic. BOTH rows lead there because
  // that page collects the name AND the address, and the backend writes them
  // in one statement — there is no way to save the name on its own.
  //
  // One test per row, each on a fresh tree: navigating back between them
  // needs a back affordance this pushed page does not expose in the test
  // environment, and pumping fresh is simpler than working around that.
  //
  // Tapped by the row's own title text rather than by the row key: the page
  // sets extendBodyBehindAppBar, so a row's geometric centre can fall under
  // the AppBar and a centre-of-widget tap misses.
  testWidgets('the company-name row opens the corporate-email page', (
    tester,
  ) async {
    await tester.pumpWidget(_appWith(_FakeAuthService()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Company / Organisation'));
    await tester.pumpAndSettle();

    expect(find.byType(CorporateEmailVerificationPage), findsOneWidget);
  });

  testWidgets('the company-email row opens the same corporate-email page', (
    tester,
  ) async {
    await tester.pumpWidget(_appWith(_FakeAuthService()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Company / Organisation Email'));
    await tester.pumpAndSettle();

    expect(find.byType(CorporateEmailVerificationPage), findsOneWidget);
  });

  testWidgets(
    'a user who has not finished Level 2 is sent there first, and the new '
    'rows stay locked',
    (tester) async {
      await tester.pumpWidget(_appWith(_FakeAuthService(levelTwoDone: false)));
      await tester.pumpAndSettle();

      // Once as the block's heading, once per locked row beneath it.
      expect(
        find.byKey(const Key('hostingUnlockLevelTwoHeading')),
        findsOneWidget,
      );
      expect(find.text('Finish Level 2 first'), findsNWidgets(3));
      expect(_completeEnabled(tester), isFalse);

      await tester.ensureVisible(
        find.byKey(const Key('hostingUnlockLevelTwoLink')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hostingUnlockLevelTwoLink')));
      await tester.pumpAndSettle();
      expect(find.byType(VerificationChecklistPage), findsOneWidget);
    },
  );

  testWidgets('the Level 2 prerequisite block is hidden once Level 2 is done', (
    tester,
  ) async {
    await tester.pumpWidget(_appWith(_FakeAuthService()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('hostingUnlockLevelTwoHeading')), findsNothing);
    expect(find.byKey(const Key('hostingUnlockLevelTwoLink')), findsNothing);
  });
}
