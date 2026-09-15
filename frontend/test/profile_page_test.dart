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
import 'package:professional_connections_platform/features/landing/landing_page.dart';
import 'package:professional_connections_platform/features/profile/profile_page.dart';
import 'package:professional_connections_platform/features/verification/corporate_email_verification_page.dart';
import 'package:professional_connections_platform/features/verification/personal_details_page.dart';
import 'package:professional_connections_platform/features/verification/personal_email_verification_page.dart';
import 'package:professional_connections_platform/features/verification/phone_verification_page.dart';

import 'support/fake_secure_storage_platform.dart';
import 'package:professional_connections_platform/features/notifications/notifications_page.dart';
import 'package:professional_connections_platform/features/privacy/privacy_controls_page.dart';

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

  _FakeAuthService({
    this.logoutShouldThrow = false,
    UserProfile? profile,
    this.completeProfileSetupError,
  }) : _profile =
           profile ??
           // An already-LinkedIn-connected user is this fake's default —
           // most tests in this file are about sign-out/verification-row
           // behavior for such a user, not about Level 0 specifically (see
           // the dedicated Level 0 group below for that case).
           //
           // linkedInConnectedFlag must now be set EXPLICITLY. Before ADR-002
           // §2, trustLevel: 1 implied it, because Level 1 was reachable only
           // via LinkedIn. It no longer does — Level 1 is now what every real
           // signup path grants — so a fixture that sets only trustLevel now
           // describes an Apple/Google/email account with no LinkedIn.
           const UserProfile(
             id: 'user-1',
             fullName: 'Ada Lovelace',
             trustLevel: 1,
             linkedInConnectedFlag: true,
           );

  final bool logoutShouldThrow;
  final UserProfile _profile;
  int logoutCallCount = 0;
  String? lastLogoutRefreshToken;

  // ADR-023 §5's full-name inline edit.
  final Object? completeProfileSetupError;
  int completeProfileSetupCallCount = 0;
  String? lastCompleteProfileSetupFullName;
  String? lastCompleteProfileSetupCompanyName;
  String? lastCompleteProfileSetupCompanyEmail;

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
  }) async {
    completeProfileSetupCallCount++;
    lastCompleteProfileSetupFullName = fullName;
    lastCompleteProfileSetupCompanyName = companyName;
    lastCompleteProfileSetupCompanyEmail = companyEmail;
    if (completeProfileSetupError != null) throw completeProfileSetupError!;
    return UserProfile(
      id: _profile.id,
      fullName: fullName,
      trustLevel: _profile.trustLevel,
    );
  }

  @override
  Future<AuthSession> refreshSession(String refreshToken) async =>
      throw UnimplementedError();

  @override
  Future<void> logout(
    String refreshToken, {
    String? accessToken,
    String? fcmToken,
  }) async {
    logoutCallCount++;
    lastLogoutRefreshToken = refreshToken;
    if (logoutShouldThrow) {
      throw const AuthNetworkException('backend unreachable');
    }
  }

  // authSessionProvider.build() calls getProfile() on every session load
  // now (frontend/PLAN.md's Level 2/3 addendum, Step 3) — every test using
  // this fake exercises this, so it needs a real implementation, not
  // UnimplementedError.
  @override
  Future<UserProfile> getProfile() async => _profile;

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

/// Pumps until `ProfilePage` is gone (sign-out navigated away) or a bounded
/// number of pumps elapses. Not `pumpAndSettle` — the destination,
/// `LandingPage`, contains `OrbitingIntents`, a perpetually-repeating
/// animation (same reason `widget_test.dart`'s smoke test uses bounded
/// pumps), so `pumpAndSettle` would never converge there. A fixed pump
/// count is fragile against how many async hops `_signOut` actually takes;
/// polling for the actual outcome isn't.
Future<void> _pumpUntilSignedOut(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    if (find.byType(ProfilePage).evaluate().isEmpty) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Taps the original SIGN OUT tile (a `FlatCard`/`GestureDetector`, not a
/// `TextButton`) to open the confirmation dialog. `find.text('SIGN OUT')`
/// is unambiguous at this point — only the trigger tile has that text
/// before the dialog exists — so this must only ever run pre-dialog.
Future<void> _tapSignOutTrigger(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('SIGN OUT'),
    500.0,
    scrollable: find.byType(Scrollable),
  );
  await tester.tap(find.text('SIGN OUT'));
  await tester.pumpAndSettle();
}

/// Taps the dialog's destructive "SIGN OUT" action. Scoped to `TextButton`
/// specifically — after the dialog opens, plain `find.text('SIGN OUT')`
/// matches both the (now-obscured) trigger tile and the dialog's own
/// title/button, but only the button is a `TextButton`.
Future<void> _confirmSignOutInDialog(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(TextButton, 'SIGN OUT'));
  await _pumpUntilSignedOut(tester);
}

Widget _appWith(AuthService authService) {
  return ProviderScope(
    overrides: [
      authServiceProvider.overrideWithValue(authService),
      sessionStorageProvider.overrideWithValue(
        SecureSessionStorage(storage: const FlutterSecureStorage()),
      ),
    ],
    child: const MaterialApp(home: ProfilePage()),
  );
}

void main() {
  late FakeSecureStoragePlatform fakePlatform;

  setUp(() async {
    fakePlatform = FakeSecureStoragePlatform();
    FlutterSecureStoragePlatform.instance = fakePlatform;
    // Seed a signed-in session so authSessionProvider's build() (which
    // ProfilePage's sign-out reads the refresh token from) has one to load,
    // same as a real signed-in user landing on this page.
    await SecureSessionStorage(
      storage: const FlutterSecureStorage(),
    ).saveSession(_testSession);
  });

  testWidgets(
    'sign out calls logout, clears the session, and navigates to LandingPage',
    (tester) async {
      final auth = _FakeAuthService();
      await tester.pumpWidget(_appWith(auth));
      await tester.pumpAndSettle();

      // full_name genuinely reaches the UI from the cached session
      // (frontend/PLAN.md Step 10 self-review item), not just parsed and
      // discarded.
      expect(find.text('Ada Lovelace'), findsOneWidget);

      await _tapSignOutTrigger(tester);
      await _confirmSignOutInDialog(tester);

      expect(auth.logoutCallCount, 1);
      expect(auth.lastLogoutRefreshToken, 'refresh-token-abc');

      expect(find.byType(LandingPage), findsOneWidget);
      expect(find.byType(ProfilePage), findsNothing);

      final storage = SecureSessionStorage(
        storage: const FlutterSecureStorage(),
      );
      expect(await storage.loadSession(), isNull);
    },
  );

  testWidgets(
    'sign out clears the session and navigates even if the logout call fails',
    (tester) async {
      final auth = _FakeAuthService(logoutShouldThrow: true);
      await tester.pumpWidget(_appWith(auth));
      await tester.pumpAndSettle();

      await _tapSignOutTrigger(tester);
      await _confirmSignOutInDialog(tester);

      expect(auth.logoutCallCount, 1);

      // Idempotent-logout spirit (frontend/PLAN.md Step 8): a failed
      // network call must not leave the user stuck signed in locally.
      expect(find.byType(LandingPage), findsOneWidget);
      expect(find.byType(ProfilePage), findsNothing);

      final storage = SecureSessionStorage(
        storage: const FlutterSecureStorage(),
      );
      expect(await storage.loadSession(), isNull);
    },
  );

  testWidgets('back button cannot return to the signed-out page', (
    tester,
  ) async {
    final auth = _FakeAuthService();
    await tester.pumpWidget(_appWith(auth));
    await tester.pumpAndSettle();

    await _tapSignOutTrigger(tester);
    await _confirmSignOutInDialog(tester);

    // pushAndRemoveUntil((route) => false) clears the whole stack, so
    // there is nothing left for a back gesture to pop to.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(await navigator.maybePop(), isFalse);
    expect(find.byType(LandingPage), findsOneWidget);
  });

  group('sign-out confirmation (frontend/PLAN.md Step 12)', () {
    testWidgets(
      'tapping SIGN OUT shows a confirmation dialog without signing out',
      (tester) async {
        final auth = _FakeAuthService();
        await tester.pumpWidget(_appWith(auth));
        await tester.pumpAndSettle();

        await _tapSignOutTrigger(tester);

        expect(find.text('Sign out of TieHere?'), findsOneWidget);
        expect(auth.logoutCallCount, 0);
        expect(find.byType(ProfilePage), findsOneWidget);

        final storage = SecureSessionStorage(
          storage: const FlutterSecureStorage(),
        );
        expect(await storage.loadSession(), isNotNull);
      },
    );

    testWidgets('Cancel dismisses the dialog and leaves the session intact', (
      tester,
    ) async {
      final auth = _FakeAuthService();
      await tester.pumpWidget(_appWith(auth));
      await tester.pumpAndSettle();

      await _tapSignOutTrigger(tester);
      await tester.tap(find.widgetWithText(TextButton, 'CANCEL'));
      await tester.pumpAndSettle();

      expect(auth.logoutCallCount, 0);
      expect(find.byType(ProfilePage), findsOneWidget);
      expect(find.byType(LandingPage), findsNothing);
      // The dialog itself is gone, not just invisible.
      expect(find.text('Sign out of TieHere?'), findsNothing);

      final storage = SecureSessionStorage(
        storage: const FlutterSecureStorage(),
      );
      expect(await storage.loadSession(), isNotNull);
    });
  });

  group('LinkedIn verification row (frontend/PLAN.md Step 14)', () {
    testWidgets(
      'shows LinkedIn Verified with no VERIFY chip once signed in; the '
      'other four rows are unaffected',
      (tester) async {
        await tester.pumpWidget(_appWith(_FakeAuthService()));
        await tester.pumpAndSettle();

        expect(find.text('LinkedIn Verified'), findsOneWidget);
        expect(find.text('Not connected'), findsNothing);

        // Only LinkedIn's check icon — Phone/Personal Email/Personal
        // Details/Work Email are all unverified on this fake's default
        // profile, so they show VERIFY chips instead.
        expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
        expect(find.text('VERIFY'), findsNWidgets(4));
        expect(find.text('Not verified'), findsNWidgets(4));
      },
    );
  });

  group('Level 0 read-only audit (ADR-014)', () {
    testWidgets(
      'Level 0 shows the Connect LinkedIn banner, LinkedIn row says Not '
      'connected, and the four verify chips are locked instead of VERIFY',
      (tester) async {
        // The hero card at the top makes the page taller than the default
        // test viewport; a tall one keeps every row built and tappable.
        tester.view.physicalSize = const Size(1000, 2600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final auth = _FakeAuthService(
          profile: const UserProfile(
            id: 'user-1',
            fullName: 'Ada Lovelace',
            trustLevel: 0,
          ),
        );
        await tester.pumpWidget(_appWith(auth));
        await tester.pumpAndSettle();

        expect(find.text('Connect LinkedIn'), findsOneWidget);
        expect(find.text('CONNECT LINKEDIN'), findsOneWidget);
        expect(find.text('Not connected'), findsOneWidget);
        expect(find.text('LinkedIn Verified'), findsNothing);

        // The four Level 2/3 rows are locked, not offered as VERIFY —
        // tapping VERIFY at Level 0 would just 403 server-side
        // (requireLinkedIn).
        expect(find.text('VERIFY'), findsNothing);
        expect(find.text('Connect LinkedIn first'), findsNWidgets(4));
        expect(find.byIcon(Icons.lock_outline_rounded), findsNWidgets(4));
      },
    );

    testWidgets('the banner is absent once LinkedIn is connected (Level 1+)', (
      tester,
    ) async {
      await tester.pumpWidget(_appWith(_FakeAuthService()));
      await tester.pumpAndSettle();

      expect(find.text('Connect LinkedIn'), findsNothing);
      expect(find.text('CONNECT LINKEDIN'), findsNothing);
    });
  });

  group('Verification rows (frontend/PLAN.md Level 2/3 addendum, Step 6)', () {
    testWidgets(
      'all four rows show Verified with a check icon once UserProfile '
      'reports them done, and no VERIFY chip remains',
      (tester) async {
        final auth = _FakeAuthService(
          profile: const UserProfile(
            id: 'user-1',
            fullName: 'Ada Lovelace',
            trustLevel: 1,
            linkedInConnectedFlag: true,
            phoneVerified: true,
            personalEmailVerified: true,
            personalDetailsComplete: true,
            workEmailVerified: true,
          ),
        );
        await tester.pumpWidget(_appWith(auth));
        await tester.pumpAndSettle();

        // LinkedIn's own check icon plus the four now-verified rows.
        expect(find.byIcon(Icons.check_circle_rounded), findsNWidgets(5));
        expect(find.text('Verified'), findsNWidgets(4));
        expect(find.text('VERIFY'), findsNothing);
        expect(find.text('Not verified'), findsNothing);

        // Every tick shares one right edge, whether or not a pencil sits
        // beside it: the status column must read as a straight line.
        final rightEdges = tester
            .widgetList(find.byIcon(Icons.check_circle_rounded))
            .map((w) => tester.getTopRight(find.byWidget(w)).dx)
            .toSet();
        expect(rightEdges, hasLength(1));
      },
    );

    testWidgets('tapping Phone\'s VERIFY chip opens PhoneVerificationPage', (
      tester,
    ) async {
      await tester.pumpWidget(_appWith(_FakeAuthService()));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('VERIFY').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('VERIFY').first);
      await tester.pumpAndSettle();

      expect(find.byType(PhoneVerificationPage), findsOneWidget);
    });

    testWidgets('tapping Personal Email\'s VERIFY chip opens '
        'PersonalEmailVerificationPage', (tester) async {
      await tester.pumpWidget(_appWith(_FakeAuthService()));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('VERIFY').at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('VERIFY').at(1));
      await tester.pumpAndSettle();

      expect(find.byType(PersonalEmailVerificationPage), findsOneWidget);
    });

    testWidgets(
      'tapping Personal Details\' VERIFY chip opens PersonalDetailsPage',
      (tester) async {
        await tester.pumpWidget(_appWith(_FakeAuthService()));
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.text('VERIFY').at(2));
        await tester.pumpAndSettle();
        await tester.tap(find.text('VERIFY').at(2));
        await tester.pumpAndSettle();

        expect(find.byType(PersonalDetailsPage), findsOneWidget);
      },
    );

    testWidgets('tapping Work Email\'s VERIFY chip opens '
        'CorporateEmailVerificationPage', (tester) async {
      await tester.pumpWidget(_appWith(_FakeAuthService()));
      await tester.pumpAndSettle();

      final workEmailVerify = find.text('VERIFY').at(3);
      await tester.ensureVisible(workEmailVerify);
      await tester.pumpAndSettle();
      await tester.tap(workEmailVerify);
      await tester.pumpAndSettle();

      expect(find.byType(CorporateEmailVerificationPage), findsOneWidget);
    });

    testWidgets('a verified row shows a pencil icon next to its checkmark, so '
        'editability is actually discoverable, not just an invisible tap '
        'target (ADR-023 §5)', (tester) async {
      final auth = _FakeAuthService(
        profile: const UserProfile(
          id: 'user-1',
          fullName: 'Ada Lovelace',
          trustLevel: 1,
          linkedInConnectedFlag: true,
          phoneVerified: true,
          personalEmailVerified: true,
          personalDetailsComplete: true,
          workEmailVerified: true,
        ),
      );
      await tester.pumpWidget(_appWith(auth));
      await tester.pumpAndSettle();

      // One pencil next to the display name plus one per verified row
      // (Phone/Personal Email/Personal Details/Work Email) — 5 total.
      expect(find.byIcon(Icons.edit_outlined), findsNWidgets(5));
      expect(find.text('VERIFY'), findsNothing);
    });

    testWidgets(
      'an unverified, unlocked row shows no pencil — only the VERIFY chip',
      (tester) async {
        await tester.pumpWidget(_appWith(_FakeAuthService()));
        await tester.pumpAndSettle();

        // Only the display-name pencil — none of the four rows are done.
        expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      },
    );
  });

  group('Full-name inline edit (ADR-023 §5)', () {
    testWidgets('a pencil icon next to the display name opens an edit dialog '
        'pre-filled with the current full name', (tester) async {
      await tester.pumpWidget(_appWith(_FakeAuthService()));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Edit Name'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Ada Lovelace',
      );
    });

    testWidgets(
      'editing the name and tapping SAVE calls completeProfileSetup with '
      'only the new name (companyName/companyEmail omitted) and does not '
      'crash the exit transition — regression guard for the '
      '"TextEditingController used after being disposed" bug (dispose tied '
      'to the wrong lifecycle)',
      (tester) async {
        final auth = _FakeAuthService();
        await tester.pumpWidget(_appWith(auth));
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(Icons.edit_outlined));
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), 'Augusta Ada King');
        await tester.tap(find.widgetWithText(TextButton, 'SAVE'));
        // pumpAndSettle drives the dialog's exit transition all the way to
        // completion — if the controller were disposed synchronously
        // instead of via the dialog's own State.dispose(), this is exactly
        // where the "used after being disposed" exception would surface.
        await tester.pumpAndSettle();

        expect(auth.completeProfileSetupCallCount, 1);
        expect(auth.lastCompleteProfileSetupFullName, 'Augusta Ada King');
        expect(auth.lastCompleteProfileSetupCompanyName, isNull);
        expect(auth.lastCompleteProfileSetupCompanyEmail, isNull);
        expect(find.text('Augusta Ada King'), findsOneWidget);
      },
    );

    testWidgets('CANCEL dismisses the dialog without calling '
        'completeProfileSetup', (tester) async {
      final auth = _FakeAuthService();
      await tester.pumpWidget(_appWith(auth));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Someone Else');
      await tester.tap(find.widgetWithText(TextButton, 'CANCEL'));
      await tester.pumpAndSettle();

      expect(auth.completeProfileSetupCallCount, 0);
      expect(find.text('Ada Lovelace'), findsOneWidget);
    });

    testWidgets(
      'saving the exact same name is a no-op — completeProfileSetup is not '
      'called',
      (tester) async {
        final auth = _FakeAuthService();
        await tester.pumpWidget(_appWith(auth));
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(Icons.edit_outlined));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'SAVE'));
        await tester.pumpAndSettle();

        expect(auth.completeProfileSetupCallCount, 0);
      },
    );

    testWidgets(
      'a failure surfaces the mapped error via a snack, without crashing',
      (tester) async {
        final auth = _FakeAuthService(
          completeProfileSetupError: const AuthNetworkException(
            'Something went wrong.',
          ),
        );
        await tester.pumpWidget(_appWith(auth));
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(Icons.edit_outlined));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'New Name');
        await tester.tap(find.widgetWithText(TextButton, 'SAVE'));
        await tester.pumpAndSettle();

        expect(find.text('Something went wrong.'), findsOneWidget);
      },
    );
  });

  /// # THE STATS ROW SHOWS REAL DATA
  ///
  /// All three chips were reviewed together after MEETUPS was found
  /// hardcoded to '12' — shown identically to an account created seconds
  /// earlier. Two of the three were wrong:
  ///
  ///   * MEETUPS was the literal '12';
  ///   * RATING could only ever render its "no ratings" dash, because the
  ///     gateway's profile JSON dropped rating_average/rating_count entirely
  ///     (they were populated all the way up to it and then not serialized).
  ///
  /// Both are fixed, so both are pinned here.
  group('profile stats row', () {
    testWidgets('a brand-new account shows 0 meetups and no rating — never a '
        'fabricated number', (tester) async {
      await tester.pumpWidget(
        _appWith(
          _FakeAuthService(
            profile: const UserProfile(
              id: 'user-1',
              fullName: 'Ada Lovelace',
              trustLevel: 1,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('MEETUPS'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
      expect(
        find.text('12'),
        findsNothing,
        reason: 'the old hardcoded literal must never reappear',
      );

      // No ratings yet is a dash, not a score of 0 — an average over zero
      // ratings is not a rating.
      expect(find.text('RATING'), findsOneWidget);
      expect(find.text('-'), findsOneWidget);
    });

    testWidgets('a user with history shows their real counts', (tester) async {
      await tester.pumpWidget(
        _appWith(
          _FakeAuthService(
            profile: const UserProfile(
              id: 'user-1',
              fullName: 'Ada Lovelace',
              trustLevel: 2,
              meetupsCompleted: 7,
              ratingAverage: 4.75,
              ratingCount: 4,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('7'), findsOneWidget);
      // One decimal place, from the real average rather than a placeholder.
      expect(find.text('4.8'), findsOneWidget);
      // The stat tile prints the level over its own TRUST label.
      expect(find.text('L2'), findsOneWidget);
    });
  });

  // Every one of these rows used to respond only where a glyph was painted
  // — the label or the chevron — with dead space between them, because the
  // GestureDetector defaulted to deferToChild over a Row that is mostly
  // transparent padding.
  group('a preference row is tappable across its whole width', () {
    /// Taps the row's empty middle: past the title text, well short of the
    /// trailing chevron. Under deferToChild this hits nothing.
    Future<void> tapRowGap(WidgetTester tester, String title) async {
      final row = find.ancestor(
        of: find.text(title),
        matching: find.byType(GestureDetector),
      );
      expect(row, findsWidgets);
      final box = tester.getRect(row.first);
      await tester.tapAt(Offset(box.right - 60, box.center.dy));
      await tester.pumpAndSettle();
    }

    testWidgets('Privacy Controls opens from the gap', (tester) async {
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_appWith(_FakeAuthService()));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Privacy Controls'));
      await tester.pumpAndSettle();

      await tapRowGap(tester, 'Privacy Controls');
      expect(find.byType(PrivacyControlsPage), findsOneWidget);
    });

    testWidgets('Notifications opens from the gap, and is no longer '
        '"Coming soon"', (tester) async {
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_appWith(_FakeAuthService()));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Notifications'));
      await tester.pumpAndSettle();

      expect(find.text('SOON'), findsNothing);

      await tapRowGap(tester, 'Notifications');
      expect(find.byType(NotificationsPage), findsOneWidget);
    });
  });
}
