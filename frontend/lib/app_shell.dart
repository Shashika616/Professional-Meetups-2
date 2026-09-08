import 'dart:async' show StreamSubscription, unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/services/push_notification_service.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_bottom_bar.dart';
import 'package:professional_connections_platform/features/home/home_page.dart';
import 'package:professional_connections_platform/features/landing/landing_page.dart';
import 'package:professional_connections_platform/features/meetups/events_page.dart';
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
    // Tab 1 was MatchesPage (browse open meetups). That page is gone —
    // browsing is inline on Home now — and this slot is the user's own
    // meetups, which previously had no persistent home at all and was
    // reachable only through two chips on Home's header.
    EventsPage(),
    SafetyPage(),
    // Chats removed for now (2026-09-08) — see app_bottom_bar.dart's comment.
    // features/chats/chats_page.dart is untouched on disk; re-add the import
    // and this entry (and app_bottom_bar.dart's item) when it's real.
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

  /// What happens when a push arrives.
  ///
  /// # THE FOREGROUND IS THE CASE THAT NEEDED FIXING
  ///
  /// FCM shows no system banner while the app is open, on either platform —
  /// so a user actively using the app was the ONE audience that learned
  /// nothing when something happened. This is where they get told.
  ///
  /// It also used to do nothing at all: the branch below was
  /// `message.type == 'meetup_closed'`, and the backend never set a `type`
  /// on any notification, so it was always comparing against `''`. No
  /// banner, no notice, and no refresh. The types are now sent (see the
  /// meetup module's Type* constants) and every one of them is handled here.
  ///
  /// A TAPPED notification is deliberately not toasted — the user has just
  /// read it, and echoing it over the screen they were taken to is noise.
  /// The refresh still runs, because the data behind that screen has moved
  /// either way.
  void _onPushMessage(PushMessage message) {
    _refreshFor(message.type);

    if (message.source != PushMessageSource.foreground) return;
    if (!mounted) return;

    // The server already wrote copy fit for a notification tray; re-writing
    // it here would mean two places to keep in sync and a client that lies
    // about what the server said. Falls back to the type only if a message
    // somehow arrives with no notification payload (data-only push).
    final text = message.body.isNotEmpty
        ? message.body
        : (message.title.isNotEmpty ? message.title : null);
    if (text == null) return;

    showSnack(context, text, type: _toastTypeFor(message.type));
  }

  /// Refetches whatever this notification's subject touched.
  ///
  /// Deliberately the same providers the pull-to-refresh and app-resume
  /// paths already invalidate — this is not a new refresh concept, just a
  /// third trigger for it.
  void _refreshFor(String type) {
    switch (type) {
      // Anything that changes a meetup's own lifecycle or membership shows
      // up in both the active-meetups strip and the user's own lists.
      case 'meetup_closed':
      case 'meetup_cancelled':
      case 'meetup_full':
      case 'request_accepted':
      case 'request_declined':
        ref.invalidate(activeMeetupsProvider);
        ref.invalidate(myMeetupsProvider);
      // Host-side request activity changes only the requests the host sees.
      case 'join_request':
      case 'request_withdrawn':
      case 'participant_declined':
        ref.invalidate(myMeetupsProvider);
      // A new meetup nearby changes what Home can browse.
      case 'meetup_nearby':
        ref.invalidate(openMeetupsProvider);
      // safety_checklist points at a meetup the user already has; nothing
      // listed changes, so nothing is refetched.
    }
  }

  /// Colour-codes the toast by what the news actually is, rather than
  /// showing everything as neutral information.
  ToastType _toastTypeFor(String type) {
    switch (type) {
      case 'request_accepted':
        return ToastType.success;
      case 'request_declined':
      case 'meetup_cancelled':
      case 'meetup_full':
      case 'participant_declined':
        return ToastType.error;
      default:
        return ToastType.info;
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = ref.watch(currentTabIndexProvider);

    // Keeps the PageView in sync with tab changes that didn't come from a
    // swipe — the bottom nav bar, or a page that sets the provider itself.
    // (It used to say "or HomePage's FIND MATCHES button jumping straight
    // to the Matches tab"; both that button and that tab are gone, and the
    // bar is the only such source today.) A swipe's own onPageChanged below
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
