import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/features/home/widgets/active_meetups_section.dart';
import 'package:professional_connections_platform/features/home/widgets/happening_soon_section.dart';
import 'package:professional_connections_platform/features/home/viewer_location_provider.dart';
import 'package:professional_connections_platform/features/home/widgets/home_header.dart';
import 'package:professional_connections_platform/features/home/widgets/intent_filter_bar.dart';
import 'package:professional_connections_platform/features/home/widgets/safety_tip_card.dart';
import 'package:professional_connections_platform/features/meetups/schedule_flow.dart';
import 'package:professional_connections_platform/features/verification/hosting_unlock_page.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

/// # WHAT CHANGED HERE, AND WHY
///
/// Home became the browsing surface. Before, it was a launchpad: a grid of
/// intent tiles, a stats row, and a FIND MATCHES button whose only job was to
/// switch to a separate "Matches" tab that did the actual browsing. That tab
/// is gone and its list is inline here, which removes a whole navigation
/// step from the app's primary action.
///
/// Consequences visible in this file:
///
///   * FIND MATCHES is REMOVED, not hidden — with browsing on this page
///     there is nowhere for it to navigate to. Its handler went with it.
///   * The intent grid became a one-row [IntentFilterBar] with an "All"
///     option, sitting directly above the list it filters.
///   * "Your Stats" (NetworkInsightsRow) is deleted outright.
///   * HOST YOUR OWN MEETUP is now the only bottom CTA and takes the full
///     primary-button treatment, rather than remaining the smaller outlined
///     sibling of a button that no longer exists.
///   * The header's two "Your Meetings"/"Requested Meetups" chips are gone —
///     that is the Events tab now.
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

/// # WHY THIS STATE IS KEPT ALIVE
///
/// AppShell puts the four tabs in a `PageView`, whose default cache window is
/// narrower than one screen. A full swipe therefore does not merely scroll
/// this page off — it DISPOSES the whole Element/State subtree. Every
/// provider this page watches is `.autoDispose` and this page is their only
/// subscriber, so the cached data went out with it, and swiping back
/// remounted from `AsyncLoading` and rendered a flat grey skeleton until the
/// refetch landed. That sequence was the reported "gets all grey and then
/// loads".
///
/// `AutomaticKeepAliveClientMixin` is the standard fix for exactly this
/// (a PageView/TabBarView child losing state on scroll), not a workaround.
/// AppShell's own class comment already claimed the pages were "kept alive
/// by PageView" — nothing enforced that until this mixin.
///
/// NOTE the deliberate non-fix: `.autoDispose` stays on the providers. It is
/// doing a second, correct job — freeing the previous intent-filtered
/// `openMeetupsProvider.family` instance when the filter changes — which has
/// nothing to do with this bug. Removing it would paper over page disposal
/// while leaking a provider instance per filter change.
class _HomePageState extends ConsumerState<HomePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  /// This page's own scroll position, and the thing that drives "Happening
  /// Soon"'s infinite scroll.
  ///
  /// # WHY IT IS EXPLICIT NOW
  ///
  /// It used to be the ListView's implicit default controller, which nothing
  /// could reach. The browse list nested below is shrink-wrapped and does
  /// not scroll itself, so it has no scroll position of its own to watch —
  /// it has to watch THIS one. Without the controller being nameable, there
  /// was nothing to hand it, and the list silently never loaded past page
  /// one (docs/plans/07-happening-soon-pagination-fix.md).
  final ScrollController _scrollController = ScrollController();

  /// The subscription that keeps viewerLocationProvider alive for this
  /// page's lifetime. Held so it can be CLOSED: without that, every
  /// HomePage teardown (sign-out, forced session expiry) left a live
  /// listener behind and the autoDispose provider never disposed, which is
  /// exactly what autoDispose is there to guarantee across a sign-in cycle.
  late final ProviderSubscription<ViewerLocation> _locationListener;

  @override
  void initState() {
    super.initState();
    // Start the viewer-location read the moment Home mounts. The browse
    // section that needs it is often below the fold in a lazy ListView, and
    // when the read lived in that section's initState the permission prompt
    // and the fix waited until the user scrolled. Listening from here keeps
    // the autoDispose provider alive for the page's lifetime and starts it
    // now; the section still watches it for state.
    _locationListener = ref.listenManual(viewerLocationProvider, (_, _) {});
  }

  @override
  void dispose() {
    _locationListener.close();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Required by AutomaticKeepAliveClientMixin — it is what registers the
    // keep-alive with the enclosing sliver. Omitting it makes the mixin a
    // silent no-op.
    super.build(context);

    // Null = "All" (every intent). See homeIntentFilterProvider.
    final intentFilter = ref.watch(homeIntentFilterProvider);

    // Same pattern ProfilePage uses — fullName/profilePhotoUrl come from the
    // cached session, "Member" is the fallback while loading or genuinely
    // absent, and an empty (not just null) photo URL counts as no photo.
    final profile = ref.watch(authSessionProvider).value?.profile;
    final fullName = profile?.fullName;
    final displayName = (fullName == null || fullName.isEmpty)
        ? 'Member'
        : fullName;
    final imageUrl = (profile?.profilePhotoUrl.isNotEmpty ?? false)
        ? profile!.profilePhotoUrl
        : null;
    // Level 0 is the safe default while the profile resolves — a guest is a
    // real, reachable account state, not just "still loading", so this must
    // never assume more than is confirmed.
    final trustLevel = profile?.trustLevel ?? 0;

    void onIntentSelected(IntentType? picked) {
      // A locked intent still explains itself rather than doing nothing.
      // Only a NAMED intent can be locked; "All" never is.
      if (picked != null && !picked.canJoin(trustLevel)) {
        showSnack(context, picked.joinLockedMessage, type: ToastType.locked);
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const VerificationChecklistPage()),
        );
        return;
      }
      ref.read(homeIntentFilterProvider.notifier).state = picked;
    }

    Future<void> onHostMeetup() async {
      // HOST-side gate (ADR-002 § 4) — Level 3 for ordinary intents, one
      // above joining, with its own destination: someone short of the HOST
      // bar may already be Level 2 and able to join, so the "unlock joining"
      // checklist would list things they finished long ago.
      //
      // With "All" selected there is no single intent to gate on, so the
      // question becomes "can this user host ANYTHING". If they can, the
      // scheduling flow's own per-intent step (which gates and redirects
      // identically) handles the rest; if they cannot host anything, there
      // is no point letting them in to discover that six times over.
      final canHostSomething = intentFilter == null
          ? IntentType.values.any((i) => i.canHost(trustLevel))
          : intentFilter.canHost(trustLevel);

      if (!canHostSomething) {
        showSnack(
          context,
          intentFilter?.hostLockedMessage ??
              'Verify your account to host meetups.',
          type: ToastType.locked,
        );
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const HostingUnlockPage()));
        return;
      }

      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const ScheduleFlowPage()));
      // Invalidates every cached (intent, coordinate, window) instance of
      // this family, not just one — this screen doesn't know which key the
      // list last used, and a freshly-hosted meetup should invalidate
      // whatever it shows next regardless.
      ref.invalidate(openMeetupsProvider);
      ref.invalidate(myMeetupsProvider);
      ref.invalidate(activeMeetupsProvider);
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            // PINNED, not the first row of the list: the greeting, bell and
            // avatar are the page's chrome, and chrome that scrolls off with
            // the feed leaves the bell unreachable mid-browse. The hairline
            // under it is what makes the content visibly pass beneath.
            HomeHeader(userName: displayName, imageUrl: imageUrl),
            Divider(height: 1, thickness: 1, color: AppPalette.hairline),
            Expanded(
              // Pull-to-refresh for the whole page. Scoped to
              // activeMeetupsProvider plus every open-meetups instance —
              // the two things on this page backed by a network read.
              child: RefreshIndicator(
                onRefresh: () async {
                  // Two independent refreshes run together: the active
                  // list, and a fresh position for the browse list (a pull
                  // after moving across town should re-centre the radius).
                  // Neither waits on, or is failed by, the other.
                  //
                  // The browse list is refetched ONCE: a moved position is
                  // a new provider key and fetches on its own, so only an
                  // unchanged one needs the explicit invalidation. The
                  // position read is bounded by its own deadline.
                  final location = ref.read(viewerLocationProvider.notifier);
                  final before = ref.read(viewerLocationProvider);
                  await Future.wait<void>([
                    location.refresh().then((_) {
                      final after = ref.read(viewerLocationProvider);
                      if (after.lat == before.lat && after.lng == before.lng) {
                        ref.invalidate(openMeetupsProvider);
                      }
                    }),
                    // The awaited value is discarded on purpose: awaiting
                    // is what makes RefreshIndicator hold its spinner until
                    // the refetch lands; the data reaches the UI through
                    // the provider's own watchers. A failure here is the
                    // provider's error state, not the pull's.
                    ref
                        .refresh(activeMeetupsProvider.future)
                        .then((_) {}, onError: (_) {}),
                  ]);
                },
                child: ListView(
                  controller: _scrollController,
                  // A RefreshIndicator can only fire on an overscroll, and a
                  // list shorter than its viewport does not scroll at all
                  // under the default physics — so pull-to-refresh silently
                  // did nothing whenever Home was short: a new account with
                  // no active meetups and nothing nearby, or one whose
                  // location is blocked. Exactly the state in which a user
                  // is most likely to pull.
                  //
                  // It was masked until now by the loading skeleton, which
                  // padded the page tall enough to scroll on the way in.
                  // Delaying the skeleton removed that accident and exposed
                  // the bug underneath; same fix, and same reasoning, as
                  // PaginatedMeetupList's own physics.
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  addAutomaticKeepAlives: true,
                  addRepaintBoundaries: true,
                  children: [
                    const SizedBox(height: 4),
                    const ActiveMeetupsSection(),
                    // The intent filter lives INSIDE this section now, not
                    // at the top of the page. It only ever filtered this
                    // list, so sitting above ActiveMeetupsSection — which it
                    // does not filter — read as a page-wide control and
                    // implied the active-meetups strip was being filtered
                    // too.
                    HappeningSoonSection(
                      intent: intentFilter,
                      trustLevel: trustLevel,
                      onSelectIntent: onIntentSelected,
                      // The bridge: this page scrolls, that section's list
                      // does not, so the section watches this controller to
                      // know when to fetch the next page.
                      outerScrollController: _scrollController,
                    ),
                    const SafetyTipCard(),
                    // Clearance above the fixed CTA block below.
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              // The sole primary action now. It was an outlined secondary
              // button when it shared this block with FIND MATCHES; with
              // that gone, leaving it outlined would read as the leftover
              // half of a removed pair rather than the page's main action.
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('hostYourOwnMeetup'),
                  onPressed: onHostMeetup,
                  icon: const Icon(Icons.add_circle_outline, size: 18),
                  label: const Text(
                    'HOST YOUR OWN MEETUP',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.0,
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                    backgroundColor: AppPalette.verified,
                    foregroundColor: Colors.black,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
