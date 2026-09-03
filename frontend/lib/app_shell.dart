import 'dart:async' show StreamSubscription, unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/push_notification_service.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_bottom_bar.dart';
import 'package:professional_connections_platform/features/chats/chats_page.dart';
import 'package:professional_connections_platform/features/home/home_page.dart';
import 'package:professional_connections_platform/features/landing/landing_page.dart';
import 'package:professional_connections_platform/features/matches/matches_page.dart';
import 'package:professional_connections_platform/features/profile/profile_page.dart';
import 'package:professional_connections_platform/features/safety/safety_page.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

/// `with WidgetsBindingObserver` (ADR-030, round-9) — AppShell is the one
/// persistent, always-mounted widget for the app's whole logged-in
/// lifetime (all five tabs are built once into `pages` below and kept
/// alive by `PageView`, not rebuilt per tab switch), so it's the right
/// single place to own both the app-resume refetch hook and the
/// long-lived push-message subscription, rather than duplicating either
/// per-page.
class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver {
  final List<Widget> pages = const [
    HomePage(),
    MatchesPage(),
    SafetyPage(),
    ChatsPage(),
    ProfilePage(),
  ];

  late final PageController _pageController;
  StreamSubscription<PushMessage>? _pushMessageSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageController = PageController(
      initialPage: ref.read(currentTabIndexProvider),
    );

    // ADR-030 (round-9 scaffolding) — initializes the push service and
    // subscribes to its message stream once, for the app's lifetime.
    // NoOpPushNotificationService.messages never emits, so
    // _onPushMessage is never actually called today — ready for a real
    // implementation to make this live with no call-site change.
    final pushService = ref.read(pushNotificationServiceProvider);
    unawaited(pushService.initialize());
    _pushMessageSubscription = pushService.messages.listen(_onPushMessage);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pushMessageSubscription?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  /// ADR-030 (round-9) — the actual fix for the reported "meetup card
  /// doesn't update when it auto-closes" bug: a one-shot, event-triggered
  /// refetch on returning to the foreground, so a meetup that auto-closed
  /// while the app was backgrounded is correct the moment the user looks
  /// again. Deliberately NOT periodic — see active_meetups_section.dart's
  /// own `Timer.periodic` doc comment for why recurring polling was
  /// considered and rejected on cost grounds.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(activeMeetupsProvider);
    }
  }

  /// ADR-030 (round-9 scaffolding) — never fires today
  /// (NoOpPushNotificationService.messages never emits), wired so a real
  /// push implementation makes it live immediately. `meetup_closed` is the
  /// one type this round's backend actually sends (ADR-025's
  /// `notifyMeetupClosed`); invalidating both providers here mirrors
  /// exactly what the pull-to-refresh/app-resume paths already invalidate,
  /// not a new refresh concept.
  void _onPushMessage(PushMessage message) {
    if (message.type == 'meetup_closed') {
      ref.invalidate(activeMeetupsProvider);
      ref.invalidate(myMeetupsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = ref.watch(currentTabIndexProvider);

    // Keeps the PageView in sync with tab changes that didn't come from a
    // swipe (the bottom nav bar, or HomePage's FIND MATCHES button jumping
    // straight to the Matches tab) — a swipe's own onPageChanged below
    // already updates the provider directly, so this only needs to act
    // when the provider changed out from under the PageView, not the
    // other way around (the page?.round() guard is what prevents those
    // two paths from fighting each other).
    ref.listen<int>(currentTabIndexProvider, (previous, next) {
      if (_pageController.hasClients && _pageController.page?.round() != next) {
        _pageController.animateToPage(
          next,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
    });
    // Safety net for any authenticated call site that forgot its own
    // SessionExpiredException catch (`frontend/PLAN.md`'s "Session refresh
    // wiring fix" addendum, Step 5.2): whenever authSessionProvider
    // transitions from logged-in to logged-out while AppShell is mounted —
    // whether via an explicit forceSignOut() elsewhere or a gap this missed
    // — land on LandingPage with a "session expired" explanation, rather
    // than stranding the user on a dead session where every action silently
    // fails. Distinct from ProfilePage's voluntary sign-out: no confirmation
    // dialog here, since nothing was confirmed — this already happened.
    ref.listen<AsyncValue<AuthSessionState>>(authSessionProvider, (
      previous,
      next,
    ) {
      final wasLoggedIn = previous?.value?.isLoggedIn ?? false;
      final isLoggedIn = next.value?.isLoggedIn ?? false;
      if (wasLoggedIn && !isLoggedIn) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (context) => const LandingPage(sessionExpired: true),
          ),
          (route) => false,
        );
      }
    });

    return Scaffold(
      // extendBody was true for the old floating pill bar, so the
      // background photo showed through the gaps around it. AppBottomBar is
      // now flush and opaque (ADR-032 round 2, reference callout #3), so
      // extending the body behind it would just hide content underneath —
      // specifically HomePage's fixed "Find matches"/"Host your own meetup"
      // block, which callout #2 requires to sit directly ABOVE the bar.
      // Laying the body out above the bar is also what makes the bar read
      // as genuinely pinned rather than overlapping the page.
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: PageView(
          controller: _pageController,
          // Swiping is now the second way to switch tabs, alongside
          // tapping the bottom nav bar — this is what keeps the bar's
          // highlighted item in sync when the switch came from a swipe
          // rather than a tap.
          onPageChanged: (index) =>
              ref.read(currentTabIndexProvider.notifier).state = index,
          children: pages,
        ),
      ),
      bottomNavigationBar: AppBottomBar(
        index: currentIndex,
        onTap: (index) =>
            ref.read(currentTabIndexProvider.notifier).state = index,
      ),
    );
  }
}
