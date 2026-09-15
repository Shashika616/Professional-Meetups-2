import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
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
import 'package:professional_connections_platform/features/meetups/schedule_flow.dart';
import 'package:professional_connections_platform/features/verification/hosting_unlock_page.dart';
import 'package:professional_connections_platform/core/widgets/empty_state_deck.dart';
import 'package:professional_connections_platform/features/profile/public_profile_page.dart';
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

  /// The empty hosted tab's way in. The same gate Home applies before the
  /// scheduling flow (ADR-002 § 4): someone below the host bar for every
  /// intent goes to the unlock page instead, with the same one-line toast.
  Future<void> _hostMeetup(BuildContext context, WidgetRef ref) async {
    final trustLevel =
        ref.read(authSessionProvider).value?.profile?.trustLevel ?? 0;
    if (!IntentType.values.any((i) => i.canHost(trustLevel))) {
      showSnack(
        context,
        'Verify your account to host meetups.',
        type: ToastType.locked,
      );
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const HostingUnlockPage()));
      return;
    }
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ScheduleFlowPage()));
    ref.invalidate(myMeetupsProvider);
    ref.invalidate(activeMeetupsProvider);
  }

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
                  emptyState: EmptyStateDeck(
                    title: 'Nothing on your calendar yet',
                    message:
                        'Meetups you host show up here, with the people who '
                        'asked to join. Put the first one on the calendar.',
                    scenes: EmptyDeckScenes.meetups,
                    actionLabel: 'HOST A MEETUP',
                    onAction: () => _hostMeetup(context, ref),
                  ),
                  historyEmptyState: const EmptyStateDeck(
                    title: 'No past meetups yet',
                    message:
                        'Once a meetup you hosted has ended, it moves here '
                        'so you can look back on it.',
                    scenes: EmptyDeckScenes.meetups,
                  ),
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
                  emptyState: const EmptyStateDeck(
                    title: 'No requests yet',
                    message:
                        'Meetups you ask to join show up here while the host '
                        'decides. Find one on Home under Happening Soon.',
                    scenes: EmptyDeckScenes.requests,
                  ),
                  historyEmptyState: const EmptyStateDeck(
                    title: 'No past meetups yet',
                    message:
                        'Meetups you joined move here once they have ended.',
                    scenes: EmptyDeckScenes.requests,
                  ),
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
    required this.emptyState,
    required this.historyEmptyState,
    required this.onTap,
  });

  final bool isHosted;
  final List<Meetup> initialItems;
  final String? initialNextCursor;
  final bool initialHasMore;

  /// What the Open and History tabs show with nothing in them.
  final Widget emptyState;
  final Widget historyEmptyState;
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
              _buildList(_isOpen, widget.emptyState),
              _buildList(_isHistory, widget.historyEmptyState),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildList(bool Function(Meetup) filter, Widget emptyState) {
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
      emptyMessage: '',
      emptyState: emptyState,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      // `previous` is unused here: Events lists are already split by tab and
      // by open/history, so a third level of grouping inside them would be
      // noise.
      itemBuilder: (context, meetup, _) => _MyMeetupTile(
        meetup: meetup,
        onTap: () => widget.onTap(meetup),
        // A live meetup the viewer hosts gets an explicit VIEW REQUESTS
        // action. It goes where tapping the tile already went; the button
        // exists because nothing on the tile said that is where it goes.
        onViewRequests: widget.isHosted && !_isFinished(meetup)
            ? () => widget.onTap(meetup)
            : null,
      ),
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

    // A TRACK holding two segments, not two free standing buttons.
    //
    // The previous version drew each half as its own bordered pill, selected
    // or not, and the only difference between the two states was a faint tint
    // and a slightly stronger border. On a dark page that read as two buttons
    // where neither looked pressed. Enclosing them in one recessed track and
    // FILLING the active half is the standard segmented control, and it is
    // unambiguous at a glance.
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: AppPalette.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppPalette.hairline),
        ),
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
      ),
    );
  }
}

/// One half of the segmented control.
///
/// Selected means FILLED, in the same colour and with the same foreground as
/// the app's primary buttons, so "this one is active" uses a signal the user
/// has already learned elsewhere in the app. Unselected is drawn as nothing at
/// all: it sits on the track and takes its contrast from the filled half
/// beside it.
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
    // Matches PrimaryButton exactly: candyBlue fill, onyx on top of it. onyx
    // is near black in dark mode and near white in light, so this stays
    // legible in both without a second rule.
    final foreground = selected ? AppPalette.onyx : AppPalette.textSecondary;

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
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            // No border on either state: the track around both halves already
            // draws the outline, and a second one inside it made the control
            // look like two boxes in a box.
            color: selected ? AppPalette.candyBlue : Colors.transparent,
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
                  style: TextStyle(
                    color: foreground,
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
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
  const _MyMeetupTile({
    required this.meetup,
    required this.onTap,
    this.onViewRequests,
  });

  final Meetup meetup;
  final VoidCallback onTap;

  /// Present only for a live meetup the viewer hosts: renders the VIEW
  /// REQUESTS action under the card body.
  final VoidCallback? onViewRequests;

  /// Green while the meetup is live, gold once it is over and owed a review,
  /// muted once there is nothing left to do with it. Same three states and the
  /// same two colours as the ACTIVE MEETUPS rows on Home, so a meetup does not
  /// change language between the two screens that show it.
  Color _edgeColor() {
    final end = meetup.windowEnd;
    final over = end != null && DateTime.now().isAfter(end);
    return switch (meetup.status) {
      MeetupStatus.cancelled => AppPalette.cancelled,
      _ when over => AppPalette.gold,
      _ => AppPalette.verified,
    };
  }

  /// The outcome chip on a History card: what became of this meetup, from
  /// the viewer's side. COMPLETED for one that ran its course; CANCELLED
  /// when the host called it off; WITHDRAWN when the viewer pulled their
  /// own request. Null on a live meetup — there is no outcome yet.
  ({String label, Color color})? _outcome() {
    if (!_isFinished(meetup)) return null;
    if (meetup.status == MeetupStatus.cancelled) {
      return (label: 'CANCELLED', color: AppPalette.cancelled);
    }
    if (!meetup.isHostedByMe &&
        meetup.myRequestStatus == MeetupRequestStatus.withdrawn) {
      return (label: 'WITHDRAWN', color: AppPalette.textSecondary);
    }
    return (label: 'COMPLETED', color: AppPalette.verified);
  }

  @override
  Widget build(BuildContext context) {
    final edge = _edgeColor();

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: FlatCard(
            radius: 14,
            padding: EdgeInsets.zero,
            child: IntrinsicHeight(
              child: Row(
                children: [
                  Container(width: 4, color: edge),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // ONE line for identity, not three.
                          //
                          // This row used to carry the intent, a status chip,
                          // a trust chip and a star rating, with a second row
                          // of verification badges under it — five competing
                          // pieces of chrome above the thing the card is
                          // actually about. The status chip is now the edge,
                          // and what is left is the intent and who is hosting.
                          Row(
                            children: [
                              Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: edge.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: Icon(
                                  meetup.intent.icon,
                                  size: 16,
                                  color: edge,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  meetup.intentLabel,
                                  style: TextStyle(
                                    color: AppPalette.textSecondary,
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.3,
                                  ),
                                ),
                              ),
                              // The star rating used to sit here too. On a
                              // 375pt screen the icon tile plus the intent
                              // label plus a trust badge plus a rating
                              // overflowed the row by 15pt, and cramming four
                              // things onto one line was the problem this
                              // redesign set out to fix anyway. The rating
                              // moved to the footer, beside the other
                              // host-credibility signals it belongs with.
                              TrustLevelBadge(
                                trustLevel: meetup.hostTrustLevel,
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          // The when, as the headline. It is the single most
                          // useful thing on a card about a meeting you already
                          // belong to, and it used to sit below two rows of
                          // badges at the same weight as everything else.
                          Text(
                            meetup.formattedWindow,
                            style: TextStyle(
                              color: AppPalette.textPrimary,
                              fontSize: 16.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.place_outlined,
                                size: 13,
                                color: AppPalette.textSecondary,
                              ),
                              const SizedBox(width: 4),
                              // locationLabel is only ever null for a locked
                              // ListOpenMeetups result (ADR-028) — this page
                              // loads via listMyMeetups, which never redacts,
                              // so `!` is safe.
                              Expanded(
                                child: Text(
                                  meetup.locationLabel!,
                                  style: TextStyle(
                                    color: AppPalette.textSecondary,
                                    fontSize: 12,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          // Its own line: VerificationBadges is a Wrap, so
                          // given the full width it reflows instead of
                          // fighting whatever shares the row with it.
                          VerificationBadges(trustLevel: meetup.hostTrustLevel),
                          const SizedBox(height: 12),
                          Divider(height: 1, color: AppPalette.hairline),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              StarRating(
                                average: meetup.hostRatingAverage,
                                count: meetup.hostRatingCount,
                              ),
                              const Spacer(),
                              Flexible(child: _statusRow(meetup)),
                            ],
                          ),
                          if (onViewRequests != null) ...[
                            const SizedBox(height: 12),
                            _ViewRequestsButton(onPressed: onViewRequests!),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusRow(Meetup meetup) {
    // On a finished meetup the viewer's request state is history, not
    // status — "YOU'RE IN" on something that already happened says nothing
    // — so the row is left to the rating. Hosts keep their confirmed count.
    final outcome = _outcome();
    if (outcome != null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: outcome.color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: outcome.color.withValues(alpha: 0.35)),
        ),
        child: Text(
          outcome.label,
          style: TextStyle(
            color: outcome.color,
            fontSize: 9.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
          ),
        ),
      );
    }
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
      MeetupRequestStatus.pending => ('REQUEST PENDING', AppPalette.gold),
      MeetupRequestStatus.accepted => ('YOU\'RE IN', AppPalette.verified),
      MeetupRequestStatus.rejected =>
        meetup.myRequestAutoRejected
            ? ('NOT SELECTED, MEETUP FILLED UP', AppPalette.textSecondary)
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
                                _meetup.intentLabel,
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
        _buildRequestList(pending, (
          title: 'No one has asked yet',
          message:
              'When someone taps I\'M INTERESTED on this meetup, their '
              'request lands here for you to accept or decline.',
        )),
        _buildRequestList(accepted, (
          title: 'No one confirmed yet',
          message: 'People you accept show up here.',
        )),
        Column(
          children: [
            Expanded(
              child: _buildRequestList(rejectedOrWithdrawn, (
                title: 'Nothing declined',
                message:
                    'Requests you decline, and people who withdraw, are kept '
                    'here for the record.',
              )),
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

  Widget _buildRequestList(
    List<MeetupRequestModel> requests,
    ({String title, String message}) empty,
  ) {
    if (requests.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          EmptyStateDeck(
            title: empty.title,
            message: empty.message,
            scenes: EmptyDeckScenes.requests,
          ),
        ],
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
            // The identity row opens the requester's public profile — the
            // host is deciding whether to let this person in, and a name
            // plus a level badge is not enough to decide on. Only the row
            // is tappable, so ACCEPT/DECLINE below stay unambiguous.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => PublicProfilePage.open(
                context,
                userId: request.requesterId,
                initialName: request.requesterFullName,
              ),
              child: Row(
                children: [
                  ProfessionalAvatar(
                    name: request.requesterFullName,
                    imageUrl: request.requesterProfilePhotoUrl.isEmpty
                        ? null
                        : request.requesterProfilePhotoUrl,
                    size: 40,
                  ),
                  const SizedBox(width: 12),
                  // Name on its own line(s), never cut; badge and rating
                  // under it — same stack as the Home card's host header.
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          request.requesterFullName,
                          softWrap: true,
                          style: TextStyle(
                            color: AppPalette.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            TrustLevelBadge(
                              trustLevel: request.requesterTrustLevel,
                            ),
                            StarRating(
                              average: request.requesterRatingAverage,
                              count: request.requesterRatingCount,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: AppPalette.textSecondary,
                  ),
                ],
              ),
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
                  // The softer red (the cancelled-meetup tone, border
                  // eased), the same treatment as CANCEL REQUEST: a
                  // decline, visibly a button, but not an alarm next to
                  // ACCEPT.
                  Expanded(
                    child: SecondaryButton(
                      label: 'REJECT',
                      height: 40,
                      color: AppPalette.cancelled,
                      borderColor: AppPalette.cancelled.withValues(alpha: 0.55),
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

/// The host's one action on a live meetup from the Events tab. Outlined
/// in the request colour rather than filled: it is a navigation into a
/// management screen, not a commitment, and a filled bar on every hosted
/// card would out-shout HOST YOUR OWN MEETUP below the list.
class _ViewRequestsButton extends StatelessWidget {
  const _ViewRequestsButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(
        Icons.people_outline_rounded,
        size: 16,
        color: AppPalette.candyBlue,
      ),
      label: Text(
        'VIEW REQUESTS',
        style: TextStyle(
          color: AppPalette.candyBlue,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.1,
        ),
      ),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(40),
        side: BorderSide(color: AppPalette.candyBlue.withValues(alpha: 0.45)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
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
