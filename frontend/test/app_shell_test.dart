import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/app_shell.dart';
import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/widgets/app_bottom_bar.dart';
import 'package:professional_connections_platform/features/landing/landing_page.dart';
import 'package:professional_connections_platform/features/matches/matches_page.dart';

import 'support/fake_meetup_service.dart';
import 'support/fake_secure_storage_platform.dart';
import 'support/scripted_meetup_service.dart';

/// AppShell's HomePage tab (like LandingPage's OrbitingIntents elsewhere in
/// this test suite) runs a perpetually-repeating animation, so
/// pumpAndSettle would never converge — bounded pumps instead, polling for
/// the actual outcome rather than guessing a fixed pump count.
Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 20; i++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// getProfile() is the only member completeVerification() reaches in the
/// second test below — everything else is unreachable and throws if that
/// assumption ever stops holding. Avoids a real HTTP attempt from
/// HttpAuthService during a widget test.
class _FakeAuthService implements AuthService {
  @override
  Future<UserProfile> getProfile() async =>
      const UserProfile(id: 'user-1', fullName: 'Ada Lovelace');

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

/// Starts already resolved to a logged-in state — real sign-in/session
/// loading isn't what this test is about, only what happens when
/// authSessionProvider's state later flips to logged-out while AppShell is
/// mounted (`frontend/PLAN.md`'s "Session refresh wiring fix" addendum,
/// Step 5.2's safety net).
class _FakeLoggedInNotifier extends AuthSessionNotifier {
  @override
  Future<AuthSessionState> build() async {
    return AuthSessionState(
      session: AuthSession(
        userId: 'user-1',
        accessToken: 'a1',
        refreshToken: 'r1',
        trustLevel: 1,
        isNewUser: false,
        accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
        fullName: 'Ada Lovelace',
        profilePhotoUrl: '',
      ),
    );
  }
}

void main() {
  setUp(() {
    // completeVerification() (exercised by the second test below) writes
    // through the real SecureSessionStorage/FlutterSecureStorage — without
    // a fake platform registered, that write hangs indefinitely under
    // flutter_tester (no real Keychain/Keystore channel available), same
    // setup every other test touching session storage already needs.
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
  });

  testWidgets(
    'forcing authSessionProvider to a logged-out state while AppShell is '
    'showing navigates to LandingPage with the session-expired message',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          authSessionProvider.overrideWith(_FakeLoggedInNotifier.new),
          authServiceProvider.overrideWithValue(_FakeAuthService()),
          // HomePage's UpcomingMeetupCard reads myMeetupsProvider (backed
          // by this) — without an override it defaults to the real
          // HttpMeetupService and attempts a live network call.
          meetupServiceProvider.overrideWithValue(ImmediateMeetupService()),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byType(AppShell).evaluate().isNotEmpty,
      );

      expect(find.byType(AppShell), findsOneWidget);
      expect(find.byType(LandingPage), findsNothing);

      container.read(authSessionProvider.notifier).forceSignOut();
      // Waits for AppShell's old route to actually be gone, not just for
      // LandingPage to appear — pushAndRemoveUntil's push transition
      // briefly keeps both in the tree while it animates.
      await _pumpUntil(
        tester,
        () =>
            find.byType(LandingPage).evaluate().isNotEmpty &&
            find.byType(AppShell).evaluate().isEmpty,
      );

      expect(find.byType(LandingPage), findsOneWidget);
      expect(find.byType(AppShell), findsNothing);

      final landingPage = tester.widget<LandingPage>(find.byType(LandingPage));
      expect(landingPage.sessionExpired, isTrue);

      // Not the voluntary sign-out confirmation dialog (ProfilePage's Step
      // 12) — this was involuntary, nothing to confirm.
      expect(find.text('Sign out of Professional Connections?'), findsNothing);

      // Lets the "session expired" toast's own 2.4s auto-dismiss timer
      // (ToastService/_ToastCard) run out before the test ends, so it
      // doesn't get flagged as a pending Timer.
      await tester.pump(const Duration(milliseconds: 2500));
    },
  );

  testWidgets(
    'a logged-in-to-logged-in transition (no actual sign-out) does not '
    'navigate away from AppShell',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          authSessionProvider.overrideWith(_FakeLoggedInNotifier.new),
          authServiceProvider.overrideWithValue(_FakeAuthService()),
          // HomePage's UpcomingMeetupCard reads myMeetupsProvider (backed
          // by this) — without an override it defaults to the real
          // HttpMeetupService and attempts a live network call.
          meetupServiceProvider.overrideWithValue(ImmediateMeetupService()),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byType(AppShell).evaluate().isNotEmpty,
      );

      // completeVerification-style update: still logged in afterward, just
      // a different session — must not be mistaken for a sign-out.
      await container
          .read(authSessionProvider.notifier)
          .completeVerification(
            AuthSession(
              userId: 'user-1',
              accessToken: 'a2',
              refreshToken: 'r2',
              trustLevel: 2,
              isNewUser: false,
              accessTokenExpiresAt: DateTime.now().add(
                const Duration(minutes: 15),
              ),
              fullName: 'Ada Lovelace',
              profilePhotoUrl: '',
            ),
          );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(AppShell), findsOneWidget);
      expect(find.byType(LandingPage), findsNothing);
    },
  );

  testWidgets('swiping the PageView switches tabs and keeps the bottom nav bar '
      'highlight in sync — previously the only way to switch tabs was '
      'tapping the bar itself', (tester) async {
    final container = ProviderContainer(
      overrides: [
        authSessionProvider.overrideWith(_FakeLoggedInNotifier.new),
        authServiceProvider.overrideWithValue(_FakeAuthService()),
        meetupServiceProvider.overrideWithValue(ImmediateMeetupService()),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AppShell()),
      ),
    );
    await _pumpUntil(tester, () => find.byType(AppShell).evaluate().isNotEmpty);

    expect(container.read(currentTabIndexProvider), 0);
    expect(tester.widget<AppBottomBar>(find.byType(AppBottomBar)).index, 0);

    // A leftward fling on the PageView is a forward swipe (Home →
    // Matches) — fling rather than drag, so the gesture carries enough
    // velocity for PageView to actually commit to the next page rather
    // than snapping back to the one it started on.
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pump();
    await _pumpUntil(
      tester,
      () => container.read(currentTabIndexProvider) == 1,
    );

    expect(container.read(currentTabIndexProvider), 1);
    expect(
      tester.widget<AppBottomBar>(find.byType(AppBottomBar)).index,
      1,
      reason:
          'the bar must highlight Matches after a swipe, not just '
          'after a tap on the bar itself',
    );
    expect(find.byType(MatchesPage), findsOneWidget);

    // Tapping the bar still works too, and animates the PageView back —
    // both paths drive the same provider rather than two sources of
    // truth that could drift apart. A deterministic pump through the
    // known 280ms animateToPage duration (app_shell.dart) rather than
    // _pumpUntil here: HomePage's perpetual animation means polling past
    // the point the tap's own effect has already landed can't be
    // distinguished from "still animating," so it isn't a reliable
    // termination condition on the way back to it.
    await tester.tap(find.text('HOME'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(container.read(currentTabIndexProvider), 0);
    expect(tester.widget<AppBottomBar>(find.byType(AppBottomBar)).index, 0);
  });

  testWidgets('the app returning to the foreground (AppLifecycleState.resumed) '
      'refetches the active-meetups list from the network — the actual fix '
      'for the reported "meetup card doesn\'t update when it auto-closes" '
      'bug (ADR-030, round-9)', (tester) async {
    final meetupService = ScriptedMeetupService();
    final container = ProviderContainer(
      overrides: [
        authSessionProvider.overrideWith(_FakeLoggedInNotifier.new),
        authServiceProvider.overrideWithValue(_FakeAuthService()),
        meetupServiceProvider.overrideWithValue(meetupService),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AppShell()),
      ),
    );
    await _pumpUntil(tester, () => find.byType(AppShell).evaluate().isNotEmpty);
    await tester.pump();

    expect(meetupService.listActiveMeetupsCallCount, 1);

    // One foreground transition, not a repeating timer — the
    // AppLifecycleState.resumed handler must fire exactly once per call
    // here, matching the one-shot, event-triggered contract (never
    // periodic polling under the hood).
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(
      meetupService.listActiveMeetupsCallCount,
      2,
      reason:
          'returning to the foreground must actually refetch, not just '
          'recompute local state',
    );

    // A second resumed event without anything in between fires again —
    // still one-shot per event, not a no-op after the first.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(meetupService.listActiveMeetupsCallCount, 3);
  });
}
