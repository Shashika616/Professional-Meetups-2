import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';

import 'package:professional_connections_platform/app_shell.dart';
import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/services/push_notification_service.dart';
import 'package:professional_connections_platform/core/services/subscription_service.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_bottom_bar.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/features/landing/landing_page.dart';
import 'package:professional_connections_platform/features/home/home_page.dart';
import 'package:professional_connections_platform/features/home/widgets/meetup_card.dart';
import 'package:professional_connections_platform/features/meetups/events_page.dart';
import 'package:professional_connections_platform/features/profile/profile_page.dart';

import 'support/fake_geolocator_platform.dart';
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

/// Feeds a controllable message stream into AppShell, standing in for FCM.
class _FakePushService implements PushNotificationService {
  _FakePushService(this._messages);

  final Stream<PushMessage> _messages;

  @override
  Future<void> initialize() async {}

  @override
  Future<String?> currentToken() async => null;

  @override
  Stream<PushMessage> get messages => _messages;
}

/// getProfile() is the only member completeVerification() reaches in the
/// second test below — everything else is unreachable and throws if that
/// assumption ever stops holding. Avoids a real HTTP attempt from
/// HttpAuthService during a widget test.
class _FakeAuthService implements AuthService {
  // ADR-002 § 3. Unused by this test — every fake in test/ implements the
  // full AuthService surface, so a new method lands here even when the test
  // never calls it.
  @override
  Future<AuthSession> guestSignup({required bool ageConfirmedOver18}) =>
      throw UnimplementedError();

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
    // Tab 0 is HomePage, whose HappeningSoonSection does an on-demand
    // location read on mount (ADR-021 §2 — it inherited this from the
    // browse page that used to be tab 1). Without a fake platform that read
    // hits the real Geolocator channel, which does not exist under
    // flutter_tester.
    GeolocatorPlatform.instance = FakeGeolocatorPlatform(
      position: testPosition(),
    );
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
    // Events) — fling rather than drag, so the gesture carries enough
    // velocity for PageView to actually commit to the next page rather
    // than snapping back to the one it started on.
    //
    // CHANGED BY THE HOME/EVENTS RESTRUCTURE: tab 1 was MatchesPage
    // (browse open meetups). Browsing is a section on Home now, and this
    // slot is the Events tab.
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
          'the bar must highlight Events after a swipe, not just '
          'after a tap on the bar itself',
    );
    expect(find.byType(EventsPage), findsOneWidget);

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

  testWidgets(
    'swiping works FROM the Events tab, in both directions — Events nests '
    'two TabBarViews inside AppShell\'s PageView, and the innermost '
    'horizontal scrollable used to swallow the drag, so Events was the one '
    'page a swipe could not leave',
    (tester) async {
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
      await _pumpUntil(
        tester,
        () => find.byType(AppShell).evaluate().isNotEmpty,
      );

      // Land on Events (tab 1) via the bar, so the starting point is not
      // itself a swipe.
      container.read(currentTabIndexProvider.notifier).state = 1;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(container.read(currentTabIndexProvider), 1);
      expect(find.byType(EventsPage), findsOneWidget);

      // Forward: Events -> Safety.
      //
      // `.first` is AppShell's own PageView: a TabBarView is a PageView
      // internally, so Events contributes two more. Targeting the outermost
      // is only how the gesture's coordinates are chosen — the drag still
      // starts on the Events content painted underneath it, hit-testing
      // through the two inner ones, which is exactly the case that used to
      // be swallowed.
      await tester.fling(
        find.byType(PageView).first,
        const Offset(-400, 0),
        1000,
      );
      await tester.pump();
      await _pumpUntil(
        tester,
        () => container.read(currentTabIndexProvider) == 2,
      );
      expect(
        container.read(currentTabIndexProvider),
        2,
        reason: 'a forward swipe on Events must reach Safety',
      );

      // Back again: Safety -> Events -> Home.
      await tester.fling(
        find.byType(PageView).first,
        const Offset(400, 0),
        1000,
      );
      await tester.pump();
      await _pumpUntil(
        tester,
        () => container.read(currentTabIndexProvider) == 1,
      );
      expect(container.read(currentTabIndexProvider), 1);

      await tester.fling(
        find.byType(PageView).first,
        const Offset(400, 0),
        1000,
      );
      await tester.pump();
      await _pumpUntil(
        tester,
        () => container.read(currentTabIndexProvider) == 0,
      );
      expect(
        container.read(currentTabIndexProvider),
        0,
        reason: 'a backward swipe on Events must reach Home',
      );
    },
  );

  /// # THE GREY FLASH
  ///
  /// Reported directly: "sliding between pages... gets all grey and then
  /// loads". A full swipe put the tab you left outside PageView's default
  /// cache window, so its whole Element/State subtree was DISPOSED — not
  /// merely scrolled off-screen. Home's providers are all `.autoDispose` and
  /// that page was their only subscriber, so the cached data went with it;
  /// swiping back remounted from AsyncLoading and rendered a flat grey
  /// SkeletonBox until the refetch landed.
  ///
  /// The fix is AutomaticKeepAliveClientMixin on each tab's State. These
  /// tests assert the OUTCOME — that a round trip neither refetches nor
  /// shows a skeleton — rather than that `wantKeepAlive` returns true, which
  /// would prove the code compiles and nothing else.
  group('tab pages survive a swipe away and back', () {
    /// Drives the tab change through the provider both AppShell and the
    /// bottom bar already use, then pumps past the 280ms animateToPage.
    /// Deterministic where a fling is not, and it exercises the same
    /// PageView scroll that a real swipe does.
    Future<void> goToTab(
      WidgetTester tester,
      ProviderContainer container,
      int index,
    ) async {
      container.read(currentTabIndexProvider.notifier).state = index;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }

    ProviderContainer containerWith(ScriptedMeetupService service) =>
        ProviderContainer(
          overrides: [
            authSessionProvider.overrideWith(_FakeLoggedInNotifier.new),
            authServiceProvider.overrideWithValue(_FakeAuthService()),
            meetupServiceProvider.overrideWithValue(service),
            // NEW, and a direct consequence of the fix under test: these
            // tests visit the Profile tab, which reads this provider. It
            // used to be disposed the moment the swipe back completed, so
            // its in-flight read went with it. Now the page is kept alive
            // deliberately, so an unresolved real read stays pending and
            // the framework fails the test for a leaked Timer. Resolving it
            // synchronously keeps these tests about keep-alive rather than
            // about subscription plumbing.
            subscriptionStatusProvider.overrideWith(
              (ref) async => const SubscriptionStatus(
                tier: SubscriptionTier.free,
                status: SubscriptionLifecycleStatus.none,
              ),
            ),
          ],
        );

    testWidgets(
      'Home keeps its loaded data across a swipe to the far tab and back — '
      'no refetch, and no skeleton on the way back',
      (tester) async {
        final service = ScriptedMeetupService();
        final container = containerWith(service);
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
        await tester.pump();

        expect(service.listActiveMeetupsCallCount, 1);
        expect(find.byType(HomePage), findsOneWidget);

        // Away to the furthest tab, then back.
        await goToTab(tester, container, 3);
        expect(find.byType(ProfilePage), findsOneWidget);

        await goToTab(tester, container, 0);

        expect(
          service.listActiveMeetupsCallCount,
          1,
          reason:
              'Home was rebuilt from scratch on the way back — that refetch '
              'is the grey flash the user reported',
        );
        expect(find.byType(HomePage), findsOneWidget);
        // Nothing is mid-load: the skeleton is what "grey" meant.
        expect(find.byType(MeetupsSkeleton), findsNothing);
      },
    );

    testWidgets(
      'Events keeps its loaded data across the same round trip — it took the '
      'largest structural change (ConsumerWidget -> ConsumerStatefulWidget), '
      'so it is asserted separately rather than assumed to follow Home',
      (tester) async {
        final service = ScriptedMeetupService();
        final container = containerWith(service);
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

        await goToTab(tester, container, 1);
        expect(find.byType(EventsPage), findsOneWidget);
        final callsAfterFirstVisit = service.listMyMeetupsCallCount;
        expect(callsAfterFirstVisit, greaterThanOrEqualTo(1));

        await goToTab(tester, container, 3);
        await goToTab(tester, container, 1);

        expect(
          service.listMyMeetupsCallCount,
          callsAfterFirstVisit,
          reason: 'Events refetched on the way back — it was disposed',
        );
        expect(find.byType(EventsPage), findsOneWidget);
      },
    );

    testWidgets(
      'the tab you left is still MOUNTED after swiping away — the direct '
      'statement of what keep-alive buys, and what makes the two assertions '
      'above possible',
      (tester) async {
        final service = ScriptedMeetupService();
        final container = containerWith(service);
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

        expect(find.byType(HomePage), findsOneWidget);

        await goToTab(tester, container, 3);

        expect(
          find.byType(HomePage, skipOffstage: false),
          findsOneWidget,
          reason:
              'Home must still be in the tree after swiping to Profile — '
              'without keep-alive its whole State subtree is disposed',
        );
      },
    );
  });

  /// # THE EXACT SEQUENCE THE USER REPORTED
  ///
  /// Round 08 added AutomaticKeepAliveClientMixin to all four tabs and
  /// proved it with ONE round trip (Home -> distant tab -> Home). The flash
  /// was then reported again on a longer path: Home -> Events -> Safety ->
  /// Events -> Home, tapping the bottom bar each step and landing on every
  /// tab in between.
  ///
  /// That is a genuinely different exercise: Events is visited TWICE, there
  /// are four consecutive transitions, and every intermediate page is built.
  /// So this reproduces it exactly rather than assuming the earlier test
  /// covered it — driving the bottom bar the way a user does, not
  /// jumpToPage.
  ///
  /// Assertions are made after ONE OR TWO frames, not pumpAndSettle: the bug
  /// is a transient frame, and settling first would hide precisely the thing
  /// being looked for.
  group('repeated Home <-> Events <-> Safety navigation', () {
    /// Taps a bottom-nav item and advances past the 280ms animateToPage,
    /// then hands back control with the tree in its just-landed state.
    Future<void> tapTab(WidgetTester tester, String label) async {
      await tester.tap(find.text(label));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }

    /// Taps and advances a SINGLE frame — the granularity a transient
    /// one-frame flash would actually show up at.
    Future<void> tapTabOneFrame(WidgetTester tester, String label) async {
      await tester.tap(find.text(label));
      await tester.pump();
    }

    /// Skeletons anywhere in the tree, including offstage pages — a page
    /// being rebuilt behind the animation counts, since that is what the
    /// user sees mid-swipe.
    int skeletonCount() =>
        find.byType(SkeletonBox, skipOffstage: false).evaluate().length +
        find.byType(MeetupsSkeleton, skipOffstage: false).evaluate().length;

    int skeletonsIn(Type page) => find
        .descendant(
          of: find.byType(page, skipOffstage: false),
          matching: find.byType(SkeletonBox, skipOffstage: false),
          skipOffstage: false,
        )
        .evaluate()
        .length;

    testWidgets(
      'Home -> Events -> Safety -> Events -> Home refetches nothing and '
      'never re-renders a skeleton',
      (tester) async {
        final service = ScriptedMeetupService();
        final container = ProviderContainer(
          overrides: [
            authSessionProvider.overrideWith(_FakeLoggedInNotifier.new),
            authServiceProvider.overrideWithValue(_FakeAuthService()),
            meetupServiceProvider.overrideWithValue(service),
            subscriptionStatusProvider.overrideWith(
              (ref) async => const SubscriptionStatus(
                tier: SubscriptionTier.free,
                status: SubscriptionLifecycleStatus.none,
              ),
            ),
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
        // Let Home's own fetches resolve before the sequence starts.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        final homeActiveCalls = service.listActiveMeetupsCallCount;
        final homeOpenCalls = service.listOpenMeetupsCallCount;
        expect(homeActiveCalls, 1, reason: 'Home loaded once on first mount');

        // 2. Home -> Events.
        await tapTab(tester, 'EVENTS');
        expect(find.byType(EventsPage), findsOneWidget);
        expect(
          service.listMyMeetupsCallCount,
          1,
          reason: 'Events loads once on its first visit',
        );
        // CHANGED once SkeletonLoader's delay landed. This used to assert
        // that the first visit DOES briefly show a skeleton — it did, for a
        // single frame, because the fetch had not resolved yet.
        //
        // That one frame is now suppressed: the placeholder waits 180ms
        // before drawing anything, and this fetch resolves long before that,
        // so nothing is ever painted and there is nothing to flash. Which is
        // the entire point of the delay, so the assertion is inverted rather
        // than deleted.
        expect(
          skeletonsIn(EventsPage),
          0,
          reason:
              'a fetch this fast must not paint a placeholder at all — the '
              'one-frame skeleton here was the flash',
        );

        // 3. Events -> Safety.
        await tapTab(tester, 'SAFETY');
        expect(skeletonCount(), 0);

        // 4. Safety -> Events. The second visit — the step round 08's
        //    single round trip never exercised. Checked at ONE frame, which
        //    is where a transient flash would be.
        await tapTabOneFrame(tester, 'EVENTS');
        expect(
          skeletonCount(),
          0,
          reason:
              'a skeleton on the SECOND visit, even for one frame, is the '
              'reported grey flash',
        );
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byType(EventsPage), findsOneWidget);
        expect(
          service.listMyMeetupsCallCount,
          1,
          reason:
              'returning to Events must not refetch — a second call here is '
              'the bug regardless of whether a skeleton frame is caught',
        );
        expect(skeletonCount(), 0);

        // 5. Events -> Home.
        await tapTabOneFrame(tester, 'HOME');
        expect(
          skeletonCount(),
          0,
          reason: 'no skeleton frame on the way back to Home either',
        );
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byType(HomePage), findsOneWidget);
        expect(
          service.listActiveMeetupsCallCount,
          homeActiveCalls,
          reason: 'returning to Home must not refetch active meetups',
        );
        expect(
          service.listOpenMeetupsCallCount,
          homeOpenCalls,
          reason: 'returning to Home must not refetch nearby meetups',
        );
        expect(skeletonCount(), 0);

        // Totals across the whole sequence.
        expect(service.listMyMeetupsCallCount, 1);
        expect(service.listActiveMeetupsCallCount, 1);
      },
    );

    testWidgets(
      'the Events tab paints ONE background layer, not two — it was the only '
      'tab wrapping itself in an AppBackground while already inside '
      'AppShell\'s, which is two full-screen saveLayers and two image '
      'streams on every frame of a page transition',
      (tester) async {
        final service = ScriptedMeetupService();
        final container = ProviderContainer(
          overrides: [
            authSessionProvider.overrideWith(_FakeLoggedInNotifier.new),
            authServiceProvider.overrideWithValue(_FakeAuthService()),
            meetupServiceProvider.overrideWithValue(service),
            subscriptionStatusProvider.overrideWith(
              (ref) async => const SubscriptionStatus(
                tier: SubscriptionTier.free,
                status: SubscriptionLifecycleStatus.none,
              ),
            ),
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

        int paintedLayers() => find
            .byKey(AppBackground.layerKey, skipOffstage: false)
            .evaluate()
            .length;

        expect(paintedLayers(), 1, reason: 'AppShell paints the only one');

        await tapTab(tester, 'EVENTS');
        expect(find.byType(EventsPage), findsOneWidget);
        expect(
          paintedLayers(),
          1,
          reason:
              'EventsPage still wraps itself (it is pushed as a route '
              'elsewhere), but nested it must pass through',
        );

        // And it stays one across the whole reported sequence, including
        // while every intermediate page is built.
        await tapTab(tester, 'SAFETY');
        await tapTab(tester, 'EVENTS');
        await tapTab(tester, 'HOME');
        expect(paintedLayers(), 1);
      },
    );

    testWidgets(
      'the same sequence run twice more still refetches nothing — a leak '
      'that only shows on the third visit would look like a flaky flash',
      (tester) async {
        final service = ScriptedMeetupService();
        final container = ProviderContainer(
          overrides: [
            authSessionProvider.overrideWith(_FakeLoggedInNotifier.new),
            authServiceProvider.overrideWithValue(_FakeAuthService()),
            meetupServiceProvider.overrideWithValue(service),
            subscriptionStatusProvider.overrideWith(
              (ref) async => const SubscriptionStatus(
                tier: SubscriptionTier.free,
                status: SubscriptionLifecycleStatus.none,
              ),
            ),
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
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        for (var lap = 0; lap < 3; lap++) {
          await tapTab(tester, 'EVENTS');
          await tapTab(tester, 'SAFETY');
          await tapTab(tester, 'EVENTS');
          await tapTab(tester, 'HOME');
          expect(skeletonCount(), 0, reason: 'skeleton reappeared on lap $lap');
        }

        expect(service.listMyMeetupsCallCount, 1);
        expect(service.listActiveMeetupsCallCount, 1);
        expect(service.listOpenMeetupsCallCount, 1);
      },
    );
  });

  /// # THE FOREGROUND IS THE CASE NOBODY WAS SERVING
  ///
  /// FCM shows no system banner while the app is open, on either platform.
  /// So the user actively USING the app was the one audience that learned
  /// nothing when something happened to their meetup.
  ///
  /// And the handler that was supposed to cover it did nothing at all: it
  /// branched on `message.type == 'meetup_closed'` while the backend never
  /// set a `type` on any notification, so it always compared against `''`.
  /// No banner, no in-app notice, no refresh. None of this path had a test.
  group('a push arriving while the app is open', () {
    late StreamController<PushMessage> messages;

    setUp(() => messages = StreamController<PushMessage>.broadcast());
    tearDown(() => messages.close());

    Future<ProviderContainer> pumpShell(
      WidgetTester tester,
      ScriptedMeetupService service,
    ) async {
      final container = ProviderContainer(
        overrides: [
          authSessionProvider.overrideWith(_FakeLoggedInNotifier.new),
          authServiceProvider.overrideWithValue(_FakeAuthService()),
          meetupServiceProvider.overrideWithValue(service),
          pushNotificationServiceProvider.overrideWithValue(
            _FakePushService(messages.stream),
          ),
          subscriptionStatusProvider.overrideWith(
            (ref) async => const SubscriptionStatus(
              tier: SubscriptionTier.free,
              status: SubscriptionLifecycleStatus.none,
            ),
          ),
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
      return container;
    }

    testWidgets('shows the server\'s own copy as an in-app notice', (
      tester,
    ) async {
      final service = ScriptedMeetupService();
      await pumpShell(tester, service);

      messages.add(
        const PushMessage(
          type: 'request_accepted',
          meetupId: 'meetup-1',
          title: 'Request accepted',
          body: 'The host accepted your request to join their coffee meetup',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.text('The host accepted your request to join their coffee meetup'),
        findsOneWidget,
        reason:
            'the server already wrote tray-ready copy; rewriting it on the '
            'client would be two places to keep in sync',
      );

      // Let the toast's own auto-dismiss timer run out.
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets(
      'a TAPPED notification is not echoed back — the user just read it',
      (tester) async {
        final service = ScriptedMeetupService();
        await pumpShell(tester, service);

        messages.add(
          const PushMessage(
            type: 'request_accepted',
            meetupId: 'meetup-1',
            title: 'Request accepted',
            body: 'The host accepted your request',
            source: PushMessageSource.opened,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('The host accepted your request'), findsNothing);
      },
    );

    testWidgets(
      'it still refreshes on a tapped notification — the data behind the '
      'screen the user lands on has moved either way',
      (tester) async {
        final service = ScriptedMeetupService();
        await pumpShell(tester, service);
        final before = service.listActiveMeetupsCallCount;

        messages.add(
          const PushMessage(
            type: 'meetup_cancelled',
            meetupId: 'meetup-1',
            title: 'Meetup cancelled',
            body: 'The host cancelled your coffee meetup',
            source: PushMessageSource.opened,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(service.listActiveMeetupsCallCount, greaterThan(before));
      },
    );

    testWidgets(
      'a lifecycle notification refetches the lists it affects — this is the '
      'branch that could never fire while the backend sent no type',
      (tester) async {
        final service = ScriptedMeetupService();
        await pumpShell(tester, service);
        final before = service.listActiveMeetupsCallCount;

        messages.add(
          const PushMessage(
            type: 'meetup_closed',
            meetupId: 'meetup-1',
            title: 'Meetup ended',
            body: 'Your coffee meetup has ended. Rate your experience!',
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          service.listActiveMeetupsCallCount,
          greaterThan(before),
          reason: 'meetup_closed must refetch the active-meetups strip',
        );
        await tester.pump(const Duration(seconds: 3));
      },
    );

    testWidgets('an unknown type is shown but refetches nothing — a new '
        'server-side type must never crash an older client', (tester) async {
      final service = ScriptedMeetupService();
      await pumpShell(tester, service);
      final before = service.listActiveMeetupsCallCount;

      messages.add(
        const PushMessage(
          type: 'some_future_type',
          meetupId: 'meetup-1',
          title: 'Something new',
          body: 'A thing this client has never heard of',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.text('A thing this client has never heard of'),
        findsOneWidget,
      );
      expect(service.listActiveMeetupsCallCount, before);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
