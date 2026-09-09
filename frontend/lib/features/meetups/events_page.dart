import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/paginated_meetup_list.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/meetup_status_badge.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';
import 'package:professional_connections_platform/core/widgets/star_rating.dart';
import 'package:professional_connections_platform/core/widgets/trust_level_badge.dart';
import 'package:professional_connections_platform/core/widgets/verification_badges.dart';
import 'package:professional_connections_platform/features/meetups/meetup_detail_page.dart';
import 'package:professional_connections_platform/features/meetups/widgets/host_meetup_controls.dart';
import 'package:professional_connections_platform/features/meetups/widgets/rating_prompt.dart';

/// Meetups the signed-in user hosts or has requested to join, reachable in
/// one tap from Home (frontend/meetup-scheduling-PLAN.md Step 8). Tapping a
/// hosted meetup opens its request-management view; tapping a requested
/// meetup opens the ordinary detail page.
/// The Events tab — the signed-in user's own meetups, hosted and requested.
///
/// RENAMED from `MyMeetupsPage`, and promoted from a pushed route to one of
/// AppShell's five bottom-nav destinations. The data layer is untouched by
/// that move: same `myMeetupsProvider`, same independent hosted/requested
/// cursors, same `_RequestManagementPage`, same rating-prompt-on-reject flow.
///
/// Two levels of navigation, drawn deliberately differently so they read as
/// two levels rather than one four-item control:
///
///   My Meetings        -> Open meetups | History   (TabBar)
///   Requested Meetings -> Open meetups | History   (segmented pills)
///
/// The second level is a [_SubTabSelector] — a pair of icon+label pills that
/// drive a real [TabController], so the list beside it still swipes and
/// animates. See that widget's own comment for why it is not a second
/// TabBar.
///
/// The open/history split is still computed client-side from the already
/// fetched list (status open/full vs. completed/cancelled), exactly as it
/// was before either control existed — only the control has ever changed,
/// never the filter.
/// Why both of this page's TabBarViews refuse horizontal drags.
///
/// This page is one of AppShell's bottom-nav destinations, and AppShell puts
/// those in a `PageView` so the user can swipe Home <-> Events <-> Safety.
/// That stacks THREE horizontal gesture consumers on top of each other here:
/// AppShell's PageView, this page's tab TabBarView, and each list's
/// Open/History TabBarView.
///
/// Flutter hands a horizontal drag to the INNERMOST scrollable and never
/// passes it back to an ancestor mid-gesture, so exactly one of the three
/// can ever respond — and it was the innermost, which is why swiping on
/// Events could not reach Home or Safety at all.
///
/// The rule chosen (Shashika, 2026-09-07): a horizontal swipe means the same
/// thing everywhere in the app — move between main pages. Switching tabs
/// here is a tap, on controls that are permanently on screen a few
/// millimetres away. This is what Instagram and LinkedIn do with tabs inside
/// a bottom-nav destination, and it avoids a swipe that means something
/// different depending on which page you happen to be on.
///
/// NOT applied to `_RequestManagementPage`'s tabs: that screen is a PUSHED
/// route, so it sits outside AppShell's PageView entirely and has no
/// competing ancestor to yield to. Its tabs still swipe.
const _noSwipeInsideAppShell = NeverScrollableScrollPhysics();

/// Whether a meetup is over, or was called off.
///
/// Deliberately the same rule as `MeetupDetailPage._isPastMeetup`: the
/// routing decision and the page it routes to must agree on what "finished"
/// means, or a host could be sent to the past-meetup view and shown the live
/// one (or the reverse).
bool _isFinished(Meetup meetup) {
  if (meetup.status == MeetupStatus.cancelled) return true;
  final windowEnd = meetup.windowEnd;
  return windowEnd != null && DateTime.now().isAfter(windowEnd);
}

class EventsPage extends ConsumerStatefulWidget {
  /// [initialTab] deep-links straight to My Meetings (0, the default) or
  /// Requested Meetings (1). Kept through the rename because
  /// `meetup_detail_page.dart` still deep-links here.
  const EventsPage({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  ConsumerState<EventsPage> createState() => _EventsPageState();
}

/// # WHY THIS STATE IS KEPT ALIVE
///
/// AppShell puts the four tabs in a `PageView` whose default cache window is
/// narrower than one screen, so a full swipe DISPOSES the tab you left
/// rather than merely scrolling it off. This page's `myMeetupsProvider` is
/// `.autoDispose` and this page is its only subscriber, so the cached data
/// went with it and swiping back remounted from `AsyncLoading` — the flat
/// grey skeleton behind the reported "gets all grey and then loads".
///
/// `AutomaticKeepAliveClientMixin` is the standard fix for a PageView child
/// losing state on scroll. It needs a `State`, which is the only reason this
/// page became a `ConsumerStatefulWidget`; nothing else about it changed.
class _EventsPageState extends ConsumerState<EventsPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    // Required by the mixin — it is what registers the keep-alive with the
    // enclosing sliver. Omitting it makes the mixin a silent no-op.
    super.build(context);

    final myMeetupsAsync = ref.watch(myMeetupsProvider);

    // AppBackground is kept even though AppShell now wraps this page as one
    // of its bottom-nav destinations: meetup_detail_page.dart still PUSHES
    // this page as a route for its deep link, a pushed route is built under
    // the Navigator (which sits above AppShell), and without this the page
    // would render on plain black down that entry path.
    //
    // CORRECTED: this comment used to say nesting was "harmless — it paints
    // the same background twice". It was not. Two full-screen Image.asset
    // layers, each under its own Opacity and ColorFiltered, meant two
    // saveLayers composited on every frame of a page transition and two
    // image streams that each show a flat grey fill until they resolve —
    // on the only one of the four tabs that did it. AppBackground now
    // detects the nesting and passes through, so this line costs nothing
    // when EventsPage is a tab and still works when it is a pushed route.
    return AppBackground(
      child: DefaultTabController(
        length: 2,
        initialIndex: widget.initialTab,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('EVENTS'),
            bottom: const TabBar(
              tabs: [
                Tab(text: 'My Meetings'),
                Tab(text: 'Requested Meetings'),
              ],
            ),
          ),
          body: myMeetupsAsync.when(
            loading: () => const _MyMeetupsSkeleton(),
            error: (error, stack) => Center(
              child: FlatCard(
                radius: 12,
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.wifi_off_outlined,
                      color: AppPalette.textSecondary,
                      size: 28,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Could not load your meetups.',
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 14),
                    PrimaryButton(
                      label: 'RETRY',
                      height: 40,
                      onPressed: () => ref.invalidate(myMeetupsProvider),
                    ),
                  ],
                ),
              ),
            ),
            data: (result) => TabBarView(
              // See _noSwipeInsideAppShell — this page is a bottom-nav
              // destination, so a horizontal drag here belongs to AppShell.
              physics: _noSwipeInsideAppShell,
              children: [
                _MeetupList(
                  isHosted: true,
                  initialItems: result.hosted,
                  initialNextCursor: result.hostedNextCursor,
                  initialHasMore: result.hostedHasMore,
                  emptyMessage: 'You aren\'t hosting any meetups yet.',
                  // A finished meetup goes to the same past-meetup view a
                  // participant gets, not to request management.
                  //
                  // Request management exists to RUN a meetup — accept,
                  // reject, cancel. None of that means anything once it is
                  // over, and because it was the host's only destination the
                  // host could never reach the review section at all: they
                  // were the one person who could not see the review they
                  // had just written.
                  onTap: (meetup) async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => _isFinished(meetup)
                            ? MeetupDetailPage(meetupId: meetup.id)
                            : _RequestManagementPage(meetup: meetup),
                      ),
                    );
                    ref.invalidate(myMeetupsProvider);
                  },
                ),
                _MeetupList(
                  isHosted: false,
                  initialItems: result.requested,
                  initialNextCursor: result.requestedNextCursor,
                  initialHasMore: result.requestedHasMore,
                  emptyMessage:
                      'You haven\'t requested to join any meetups yet.',
                  onTap: (meetup) async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => MeetupDetailPage(meetupId: meetup.id),
                      ),
                    );
                    ref.invalidate(myMeetupsProvider);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown while [myMeetupsProvider] resolves, instead of a bare spinner —
/// mirrors the card shape [_MeetupList] renders once data actually
/// arrives, so the list doesn't visibly "pop" from blank to content.
class _MyMeetupsSkeleton extends StatelessWidget {
  const _MyMeetupsSkeleton();

  @override
  Widget build(BuildContext context) =>
      SkeletonLoader(child: _content(context));

  /// The placeholder shapes themselves. [SkeletonLoader] above adds the
  /// delay-before-showing and the shimmer sweep, so every caller of this
  /// widget gets both without knowing about either.
  Widget _content(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      itemCount: 3,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: FlatCard(
          radius: 12,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const SkeletonBox(width: 70, height: 11, opacity: 0.08),
                  const Spacer(),
                  const SkeletonBox(width: 28, height: 16, radius: 8),
                ],
              ),
              const SizedBox(height: 10),
              const SkeletonBox(width: 100, height: 15, opacity: 0.08),
              const SizedBox(height: 6),
              const SkeletonBox(width: 140, height: 12),
              const SizedBox(height: 10),
              const SkeletonBox(width: 90, height: 11),
            ],
          ),
        ),
      ),
    );
  }
}

/// Open vs. History is a second, orthogonal axis on top of the page's own
/// Hosting/Requested tabs (ADR-016 revives `completed`, which needs
/// somewhere to show up) — filtered client-side from the same
/// already-fetched list, not a second round trip, and not a second level
/// of [TabController] nesting for what's really just a toggle.
///
/// 2026-08-31 round-4 hardening: also owns real cursor pagination for its
/// side (hosted or requested — [isHosted] picks which), reusing
/// the shared PaginatedMeetupList's scroll-load pattern exactly (a
/// [ScrollController] with a near-bottom listener, a `_loadingMore` guard,
/// disposed in [dispose]) rather than a second implementation of the same
/// mechanism. [initialItems]/[initialNextCursor]/[initialHasMore] are
/// [EventsPage]'s first page from `myMeetupsProvider`; this widget
/// accumulates further pages itself via direct `listMyMeetups` calls.
class _MeetupList extends ConsumerStatefulWidget {
  const _MeetupList({
    required this.isHosted,
    required this.initialItems,
    required this.initialNextCursor,
    required this.initialHasMore,
    required this.emptyMessage,
    required this.onTap,
  });

  final bool isHosted;
  final List<Meetup> initialItems;
  final String? initialNextCursor;
  final bool initialHasMore;
  final String emptyMessage;
  final void Function(Meetup meetup) onTap;

  @override
  ConsumerState<_MeetupList> createState() => _MeetupListState();
}

class _MeetupListState extends ConsumerState<_MeetupList>
    with SingleTickerProviderStateMixin {
  late final TabController _subTabs;

  static bool _isOpen(Meetup m) =>
      m.status == MeetupStatus.open || m.status == MeetupStatus.full;
  static bool _isHistory(Meetup m) =>
      m.status == MeetupStatus.completed || m.status == MeetupStatus.cancelled;

  @override
  void initState() {
    super.initState();
    // Index 0 = "Open meetups", the default view (matches the previous
    // toggle's own default of _showHistory = false).
    _subTabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _subTabs.dispose();
    super.dispose();
  }

  /// Fetches the next page of whichever side this list is showing.
  ///
  /// Handed to BOTH sub-tabs: paging is a property of the underlying
  /// hosted/requested list, not of the open/history filter, which is applied
  /// client-side over whatever has been fetched. Two tabs paging the same
  /// source is correct — the alternative (per-tab cursors) would ask the
  /// server to filter by a status split it does not model.
  Future<({List<Meetup> items, String? nextCursor, bool hasMore})> _loadMore(
    String cursor,
  ) async {
    final result = await ref
        .read(meetupServiceProvider)
        .listMyMeetups(
          hostedCursor: widget.isHosted ? cursor : null,
          requestedCursor: widget.isHosted ? null : cursor,
        );
    return (
      items: widget.isHosted ? result.hosted : result.requested,
      nextCursor: widget.isHosted
          ? result.hostedNextCursor
          : result.requestedNextCursor,
      hasMore: widget.isHosted ? result.hostedHasMore : result.requestedHasMore,
    );
  }

  Future<void> _refresh() async {
    ref.invalidate(myMeetupsProvider);
    await ref.read(myMeetupsProvider.future).then((_) {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _SubTabSelector(controller: _subTabs),
        Expanded(
          child: TabBarView(
            controller: _subTabs,
            physics: _noSwipeInsideAppShell,
            children: [
              _buildList(_isOpen, widget.emptyMessage),
              _buildList(_isHistory, 'Nothing here yet.'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildList(bool Function(Meetup) filter, String emptyMessage) {
    return PaginatedMeetupList(
      items: widget.initialItems.where(filter).toList(),
      nextCursor: widget.initialNextCursor,
      hasMore: widget.initialHasMore,
      loadMore: (cursor) async {
        final next = await _loadMore(cursor);
        // The filter is applied to appended pages too — without this, a
        // page-2 fetch would append history rows into the open tab.
        return (
          items: next.items.where(filter).toList(),
          nextCursor: next.nextCursor,
          hasMore: next.hasMore,
        );
      },
      onRefresh: _refresh,
      emptyMessage: emptyMessage,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      // `previous` is unused here: Events lists are already split by tab and
      // by open/history, so a third level of grouping inside them would be
      // noise.
      itemBuilder: (context, meetup, _) =>
          _MyMeetupTile(meetup: meetup, onTap: () => widget.onTap(meetup)),
    );
  }
}

/// The Open/History control.
///
/// # WHY THIS IS NOT A SECOND TabBar
///
/// It was one, briefly. Two underlined tab bars stacked directly on top of
/// each other — the page's own My Meetings/Requested Meetings bar and this
/// one — read as one confusing four-item control rather than two levels,
/// because they were drawn identically and the only cue separating them was
/// a hairline. A segmented pill is visually subordinate to the tab bar above
/// it, which is what the hierarchy actually is.
///
/// What it deliberately KEEPS from the TabBar it replaces, and what the pair
/// of plain GestureDetectors that came before that never had:
///
///   * it drives a real [TabController], so the [TabBarView] beside it still
///     swipes between the two lists, animates, and stays in sync whichever
///     way the user drives it;
///   * it rebuilds from the controller rather than from local state, so a
///     swipe moves the selection here too;
///   * each half is a [Semantics] tab with a selected state, so the
///     accessibility layer still sees a two-tab control.
class _SubTabSelector extends StatefulWidget {
  const _SubTabSelector({required this.controller});

  final TabController controller;

  @override
  State<_SubTabSelector> createState() => _SubTabSelectorState();
}

class _SubTabSelectorState extends State<_SubTabSelector> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  // Fires on a tap AND partway through a swipe, which is the point: the
  // selection must follow the TabBarView rather than only leading it.
  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final index = widget.controller.index;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Row(
        children: [
          Expanded(
            child: _SubTabButton(
              icon: Icons.event_available_outlined,
              label: 'Open meetups',
              selected: index == 0,
              onTap: () => widget.controller.animateTo(0),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _SubTabButton(
              icon: Icons.history_rounded,
              label: 'History',
              selected: index == 1,
              onTap: () => widget.controller.animateTo(1),
            ),
          ),
        ],
      ),
    );
  }
}

/// One half of the segmented control. Flat by design — a thin border and a
/// faint tint for the selected state, matching `IntentFilterBar`'s chips on
/// Home rather than introducing a third button style to the app.
class _SubTabButton extends StatelessWidget {
  const _SubTabButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected
        ? AppPalette.candyBlue
        : AppPalette.textSecondary;

    return Semantics(
      // Still a tab to the accessibility layer, exactly as the TabBar was.
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        // Without this the gaps inside the pill (and the pill itself when
        // unselected, which paints an almost-transparent fill) would not
        // register a tap at all.
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          height: 38,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            // Opaque, matching IntentFilterBar's chips — see that widget for
            // why a low-alpha fill over AppBackground reads as a smear
            // rather than a control. This was the last use of the old
            // `glassTint` token, which is now deleted.
            color: selected
                ? AppPalette.tintedSurface(
                    AppPalette.candyBlue.withValues(alpha: 0.12),
                  )
                : AppPalette.card,
            border: Border.all(
              color: selected
                  ? AppPalette.candyBlue.withValues(alpha: 0.55)
                  : AppPalette.hairline,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: foreground),
              const SizedBox(width: 7),
              // Flexible, not a bare Text: "Open meetups" is the longer of
              // the two and the pills are equal width, so on a narrow
              // device it must ellipsize rather than overflow.
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One row on the Events list.
///
/// Was the itemBuilder body of `_MeetupListView`, which also owned the
/// ListView, the load-more spinner and the ScrollController. Those three are
/// [PaginatedMeetupList]'s job now, so what is left here is exactly the card
/// — which is all this widget was ever really about.
///
/// Distinct from `MeetupCard` (the browse card) on purpose: this one shows a
/// meetup the viewer already belongs to, so it needs no join button, no
/// locked/redacted variant (listMyMeetups never redacts) and no host
/// identity block — the host is either the viewer or someone they have
/// already been accepted by.
class _MyMeetupTile extends StatelessWidget {
  const _MyMeetupTile({required this.meetup, required this.onTap});

  final Meetup meetup;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: GestureDetector(
        onTap: onTap,
        child: FlatCard(
          radius: 12,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      meetup.intent.label,
                      style: TextStyle(
                        color: AppPalette.candyBlue,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  MeetupStatusBadge(status: meetup.status),
                  const SizedBox(width: 6),
                  TrustLevelBadge(trustLevel: meetup.hostTrustLevel),
                  const SizedBox(width: 6),
                  StarRating(
                    average: meetup.hostRatingAverage,
                    count: meetup.hostRatingCount,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              VerificationBadges(trustLevel: meetup.hostTrustLevel),
              const SizedBox(height: 6),
              Text(
                meetup.formattedWindow,
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              // locationLabel is only ever null for a locked
              // ListOpenMeetups result (ADR-028) — this page loads via
              // listMyMeetups, which never redacts, so `!` is safe.
              Text(
                meetup.locationLabel!,
                style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 10),
              _statusRow(meetup),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusRow(Meetup meetup) {
    if (meetup.isHostedByMe) {
      return Text(
        '${meetup.acceptedCount}/${meetup.capacity} confirmed',
        style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
      );
    }
    final status = meetup.myRequestStatus;
    if (status == null) {
      return const SizedBox.shrink();
    }
    final (label, color) = switch (status) {
      MeetupRequestStatus.pending => ('REQUEST PENDING', AppPalette.candyBlue),
      MeetupRequestStatus.accepted => ('YOU\'RE IN', AppPalette.verified),
      MeetupRequestStatus.rejected =>
        meetup.myRequestAutoRejected
            ? ('NOT SELECTED — MEETUP FILLED UP', AppPalette.textSecondary)
            : ('DECLINED BY HOST', AppPalette.danger),
      MeetupRequestStatus.withdrawn => ('WITHDRAWN', AppPalette.textSecondary),
    };
    return Text(
      label,
      style: TextStyle(
        color: color,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.6,
        fontSize: 11,
      ),
    );
  }
}

/// A host's view of every request on one of their meetups — Accept/Reject
/// per pending request (frontend/meetup-scheduling-PLAN.md Step 8).
class _RequestManagementPage extends ConsumerStatefulWidget {
  const _RequestManagementPage({required this.meetup});

  final Meetup meetup;

  @override
  ConsumerState<_RequestManagementPage> createState() =>
      _RequestManagementPageState();
}

class _RequestManagementPageState
    extends ConsumerState<_RequestManagementPage> {
  late Meetup _meetup;
  List<MeetupRequestModel>? _requests;
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _meetup = widget.meetup;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final service = ref.read(meetupServiceProvider);
      final requests = await service.listMeetupRequests(_meetup.id);
      // Also re-fetches the meetup itself, not just its requests — an
      // Accept here bumps acceptedCount server-side, which HostMeetupControls
      // needs to know about immediately: it hides CANCEL once a request has
      // been accepted (the backend rejects cancelling in that state), and a
      // stale local _meetup would otherwise keep showing an action that's
      // now guaranteed to 409.
      final meetup = await service.getMeetup(_meetup.id);
      if (!mounted) return;
      setState(() {
        _requests = requests;
        _meetup = meetup;
        _loading = false;
      });
    } on MeetupSessionExpiredException {
      // A 401 means the session itself is gone, so every later call
      // fails too. Falling through to the generic catch below would
      // show an error the user can only retry forever; signing out is
      // the only thing that recovers. Mirrors the AuthService
      // SessionExpiredException idiom in profile_page.dart.
      if (mounted) {
        ref.read(authSessionProvider.notifier).forceSignOut();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error is MeetupException
            ? error.message
            : 'Something went wrong. Please try again.';
        _loading = false;
      });
    }
  }

  Future<void> _respond(MeetupRequestModel request, bool accept) async {
    try {
      await ref
          .read(meetupServiceProvider)
          .respondToRequest(request.id, accept: accept);
      if (!mounted) return;
      showSnack(
        context,
        accept ? 'Request accepted.' : 'Request rejected.',
        type: ToastType.success,
      );
      await _load();
    } on MeetupSessionExpiredException {
      // A 401 means the session itself is gone, so every later call
      // fails too. Falling through to the generic catch below would
      // show an error the user can only retry forever; signing out is
      // the only thing that recovers. Mirrors the AuthService
      // SessionExpiredException idiom in profile_page.dart.
      if (mounted) {
        ref.read(authSessionProvider.notifier).forceSignOut();
      }
    } catch (error) {
      if (!mounted) return;
      showSnack(
        context,
        error is MeetupException
            ? error.message
            : 'Something went wrong. Please try again.',
        type: ToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: DefaultTabController(
        // Pending / Accepted / Rejected — the single combined list this
        // replaces showed every status inline in one scroll, making it
        // hard to see "who's still waiting" at a glance (ADR-020 §2).
        // Rejected also carries withdrawn requests, shown alongside
        // rejected ones since both represent "no longer pending, not
        // accepted" from the host's point of view.
        length: 3,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('REQUESTS'),
            bottom: const TabBar(
              tabs: [
                Tab(text: 'PENDING'),
                Tab(text: 'ACCEPTED'),
                Tab(text: 'REJECTED'),
              ],
            ),
          ),
          body: SafeArea(
            child: Column(
              children: [
                // Was previously missing entirely — this screen showed
                // requester cards with no context about the meetup itself,
                // and (the bug this addendum fixes) no way to close or
                // cancel it, even though tapping the calendar icon →
                // Hosting → a meetup is the normal way a host lands here
                // (ADR-016 addendum, 2026-08-20).
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: FlatCard(
                    radius: 12,
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _meetup.intent.label,
                                style: TextStyle(
                                  color: AppPalette.candyBlue,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                            MeetupStatusBadge(status: _meetup.status),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _meetup.formattedWindow,
                          style: TextStyle(
                            color: AppPalette.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        HostMeetupControls(
                          meetup: _meetup,
                          onChanged: (updated) =>
                              setState(() => _meetup = updated),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: _loading
                      ? const _RequestsSkeleton()
                      : _loadError != null
                      ? Center(
                          child: Text(
                            _loadError!,
                            style: TextStyle(color: AppPalette.textSecondary),
                          ),
                        )
                      : _buildRequestTabs(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRequestTabs() {
    final requests = _requests!;
    final pending = requests
        .where((r) => r.status == MeetupRequestStatus.pending)
        .toList();
    final accepted = requests
        .where((r) => r.status == MeetupRequestStatus.accepted)
        .toList();
    final rejectedOrWithdrawn = requests
        .where(
          (r) =>
              r.status == MeetupRequestStatus.rejected ||
              r.status == MeetupRequestStatus.withdrawn,
        )
        .toList();

    return TabBarView(
      children: [
        _buildRequestList(pending, 'No pending requests.'),
        _buildRequestList(accepted, 'No accepted requests yet.'),
        Column(
          children: [
            Expanded(
              child: _buildRequestList(
                rejectedOrWithdrawn,
                'No rejected or withdrawn requests.',
              ),
            ),
            // A withdrawn requester becomes ratable once — this reuses the
            // same RatingPrompt widget the happened-based flow uses
            // elsewhere rather than a bespoke picker, so the score/
            // confirmation/immutability behavior is identical everywhere
            // (ADR-020 §4).
            //
            // Scoped to the people on THIS tab. The endpoint behind
            // RatingPrompt returns everyone the viewer may rate on the
            // meetup, which once the meetup completes is every attendee —
            // so unscoped it put the post-meetup rating flow under a
            // "No rejected or withdrawn requests." empty state. It still
            // self-hides when the scoped set is empty or already rated.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: RatingPrompt(
                meetupId: _meetup.id,
                onlyUserIds: rejectedOrWithdrawn
                    .where((r) => r.status == MeetupRequestStatus.withdrawn)
                    .map((r) => r.requesterId)
                    .toSet(),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRequestList(List<MeetupRequestModel> requests, String empty) {
    if (requests.isEmpty) {
      return Center(
        child: Text(
          empty,
          style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      itemCount: requests.length,
      itemBuilder: (context, index) =>
          _RequestCard(request: requests[index], onRespond: _respond),
    );
  }
}

/// One requester's card in `_RequestManagementPage`'s Pending/Accepted/
/// Rejected tabs (ADR-020 §2) — the same row shape the old single combined
/// list used, just now reused across three filtered lists instead of one.
class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.request, required this.onRespond});

  final MeetupRequestModel request;
  final void Function(MeetupRequestModel request, bool accept) onRespond;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: FlatCard(
        radius: 12,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ProfessionalAvatar(
                  name: request.requesterFullName,
                  imageUrl: request.requesterProfilePhotoUrl.isEmpty
                      ? null
                      : request.requesterProfilePhotoUrl,
                  size: 40,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    request.requesterFullName,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TrustLevelBadge(trustLevel: request.requesterTrustLevel),
                const SizedBox(width: 6),
                StarRating(
                  average: request.requesterRatingAverage,
                  count: request.requesterRatingCount,
                ),
              ],
            ),
            const SizedBox(height: 10),
            VerificationBadges(trustLevel: request.requesterTrustLevel),
            const SizedBox(height: 12),
            if (request.status == MeetupRequestStatus.pending)
              Row(
                children: [
                  Expanded(
                    child: PrimaryButton(
                      label: 'ACCEPT',
                      height: 40,
                      onPressed: () => onRespond(request, true),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SecondaryButton(
                      label: 'REJECT',
                      height: 40,
                      onPressed: () => onRespond(request, false),
                    ),
                  ),
                ],
              )
            else
              Text(
                switch (request.status) {
                  MeetupRequestStatus.accepted => 'ACCEPTED',
                  MeetupRequestStatus.rejected =>
                    request.autoRejected
                        ? 'AUTO-REJECTED (CAPACITY FULL)'
                        : 'REJECTED',
                  MeetupRequestStatus.withdrawn => 'WITHDRAWN',
                  MeetupRequestStatus.pending => 'PENDING',
                },
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  fontSize: 11,
                ),
              ),
            // Host visibility into this accepted participant's Safety Gate
            // status (ADR-024 §6) — "he is the one who's responsible for
            // the meeting," so if an accepted participant hasn't checked
            // in, the host needs to see that here, in the same place he
            // already sees his accepted participants. The host already got
            // this via push notification the moment it happened (§4); this
            // just makes it visible without having to recall the
            // notification.
            if (request.status == MeetupRequestStatus.accepted) ...[
              const SizedBox(height: 6),
              _SafetyGateStatusLine(request: request),
            ],
            // The requester's own note left when withdrawing (ADR-020 §4) —
            // only present on a withdrawn request, shown as context ahead
            // of the "Rate" action RatingPrompt surfaces below the list.
            if (request.status == MeetupRequestStatus.withdrawn &&
                (request.withdrawalNote?.isNotEmpty ?? false)) ...[
              const SizedBox(height: 8),
              Text(
                '"${request.withdrawalNote}"',
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// An accepted participant's Safety Gate status, shown only on the ACCEPTED
/// tab (ADR-024 §6) — "Checked in", "Declined: `<reason>`", or "Not checked
/// in yet". [request.checkedInAt]/[request.declinedAt] are mutually
/// exclusive (enforced server-side); pending/rejected/withdrawn requests
/// never reach this widget at all (gated by the caller).
class _SafetyGateStatusLine extends StatelessWidget {
  const _SafetyGateStatusLine({required this.request});

  final MeetupRequestModel request;

  @override
  Widget build(BuildContext context) {
    if (request.checkedInAt != null) {
      return _statusRow(Icons.check_circle, AppPalette.verified, 'Checked in');
    }
    if (request.declinedAt != null) {
      final reason = request.declineReason;
      return _statusRow(
        Icons.cancel,
        AppPalette.danger,
        (reason == null || reason.isEmpty) ? 'Declined' : 'Declined: $reason',
      );
    }
    return _statusRow(
      Icons.hourglass_empty,
      AppPalette.textSecondary,
      'Not checked in yet',
    );
  }

  Widget _statusRow(IconData icon, Color color, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 11,
            ),
          ),
        ),
      ],
    );
  }
}

/// Shown while [MeetupService.listMeetupRequests] resolves — mirrors the
/// card shape `_RequestCard` renders once data actually arrives.
class _RequestsSkeleton extends StatelessWidget {
  const _RequestsSkeleton();

  @override
  Widget build(BuildContext context) =>
      SkeletonLoader(child: _content(context));

  /// The placeholder shapes themselves. [SkeletonLoader] above adds the
  /// delay-before-showing and the shimmer sweep, so every caller of this
  /// widget gets both without knowing about either.
  Widget _content(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      itemCount: 3,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: FlatCard(
          radius: 12,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const SkeletonBox(width: 40, height: 40, radius: 20),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: SkeletonBox(
                      width: double.infinity,
                      height: 14,
                      opacity: 0.08,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const SkeletonBox(width: 28, height: 16, radius: 8),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: SkeletonBox(
                      width: double.infinity,
                      height: 40,
                      radius: 10,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SkeletonBox(
                      width: double.infinity,
                      height: 40,
                      radius: 10,
                      opacity: 0.04,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
