import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/meetup_date_filter.dart';
import 'package:professional_connections_platform/core/widgets/empty_section.dart';
import 'package:professional_connections_platform/features/meetups/widgets/intent_filter_fab.dart';
import 'package:professional_connections_platform/features/meetups/widgets/meetup_date_filter_bar.dart';
import 'package:professional_connections_platform/core/analytics/analytics.dart';
import 'package:professional_connections_platform/core/analytics/screen_names.dart';
import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/app_tag.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/load_failed_state.dart';
import 'package:professional_connections_platform/core/widgets/paginated_meetup_list.dart';
import 'package:professional_connections_platform/core/widgets/pressable.dart';
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

part 'events_my_meetups.dart';
part 'events_request_management.dart';

/// Meetups the signed-in user hosts or has requested to join, reachable in
/// one tap from Home (frontend/meetup-scheduling-PLAN.md Step 8). Tapping a
/// hosted meetup opens its request-management view; tapping a requested
/// meetup opens the ordinary detail page.
/// The Events tab — the signed-in user's own meetups, hosted and requested.
///
/// RENAMED from `MyMeetupsPage`, and promoted from a pushed route to one of
/// AppShell's five bottom-nav destinations. The data layer is untouched by
/// that move: same `myMeetupsProvider`, same independent hosted/requested
/// cursors, same `RequestManagementPage`, same rating-prompt-on-reject flow.
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
/// NOT applied to `RequestManagementPage`'s tabs: that screen is a PUSHED
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
    track(Cta.scheduleMeetup);
    final trustLevel =
        ref.read(authSessionProvider).value?.profile?.trustLevel ?? 0;
    if (!IntentType.values.any((i) => i.canHost(trustLevel))) {
      showSnack(
        context,
        'Verify your account to host meetups.',
        type: ToastType.locked,
      );
      await Navigator.of(context).push(
        MaterialPageRoute(
          settings: const RouteSettings(name: ScreenNames.hostingUnlock),
          builder: (_) => const HostingUnlockPage(),
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        settings: const RouteSettings(name: ScreenNames.scheduleMeetup),
        builder: (_) => const ScheduleFlowPage(),
      ),
    );
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
            title: const Text('Events'),
            bottom: const TabBar(
              tabs: [
                Tab(text: 'My meetings'),
                Tab(text: 'Requested meetings'),
              ],
            ),
          ),
          body: myMeetupsAsync.when(
            loading: () => const _MyMeetupsSkeleton(),
            // The skeleton stays up a moment after the failure, then the
            // page says what went wrong, with the picture every failed
            // load in the app shares.
            error: (error, stack) => SkeletonThenFailure(
              skeleton: const _MyMeetupsSkeleton(),
              failure: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  LoadFailedState(
                    failure: LoadFailure.of(error),
                    onRetry: () => ref.invalidate(myMeetupsProvider),
                  ),
                ],
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
                    message: 'Meetups you host show up here.',
                    scenes: EmptyDeckScenes.meetups,
                    actionLabel: 'Host a meetup',
                    onAction: () => _hostMeetup(context, ref),
                  ),
                  historyEmptyState: const EmptyStateDeck(
                    title: 'No past meetups yet',
                    message: 'Meetups you hosted move here once they end.',
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
                        settings: RouteSettings(
                          name: _isFinished(meetup)
                              ? ScreenNames.meetupDetail
                              : ScreenNames.requestManagement,
                        ),
                        builder: (_) => _isFinished(meetup)
                            ? MeetupDetailPage(meetupId: meetup.id)
                            : RequestManagementPage(meetup: meetup),
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
                        'Meetups you ask to join show up here while the host decides.',
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
                        settings: const RouteSettings(
                          name: ScreenNames.meetupDetail,
                        ),
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
  const _MyMeetupsSkeleton({this.withAction = false});

  /// Draws the View requests button that live hosted cards carry.
  final bool withAction;

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
        // Traced from _MeetupCard above: same surface radius, same
        // padding, and the 38px intent tile that card leads with. The
        // placeholder drifted when the card lost its left bar and went up
        // to radius 20, and a skeleton that no longer matches its card is
        // just a differently-shaped flash.
        child: FlatCard(
          radius: 20,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const SkeletonBox(width: 38, height: 38, radius: 13),
                  const SizedBox(width: 10),
                  const SkeletonBox(width: 96, height: 12, opacity: 0.08),
                  const Spacer(),
                  // The trust pill.
                  const SkeletonBox(width: 62, height: 22, radius: 11),
                ],
              ),
              const SizedBox(height: 12),
              // The time as the headline, then the address with its pin.
              const SkeletonBox(width: 180, height: 20, opacity: 0.08),
              const SizedBox(height: 5),
              const Row(
                children: [
                  SkeletonBox(width: 13, height: 13, radius: 4),
                  SizedBox(width: 4),
                  SkeletonBox(width: 190, height: 14),
                ],
              ),
              const SizedBox(height: 10),
              // The verification badges.
              const Row(
                children: [
                  SkeletonBox(width: 92, height: 24, radius: 12),
                  SizedBox(width: 8),
                  SkeletonBox(width: 70, height: 24, radius: 12),
                ],
              ),
              const SizedBox(height: 12),
              Divider(height: 1, color: AppPalette.hairline),
              const SizedBox(height: 10),
              // The rating and the status.
              const Row(
                children: [
                  SkeletonBox(width: 76, height: 14),
                  Spacer(),
                  SkeletonBox(width: 72, height: 14),
                ],
              ),
              if (withAction) ...[
                const SizedBox(height: 12),
                const SkeletonBox(
                  width: double.infinity,
                  height: 40,
                  radius: 12,
                ),
              ],
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
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late final TabController _subTabs;

  /// The intent applies to both sub-tabs. Each keeps its own date, since one
  /// looks forward and the other back. Null means no filter.
  IntentType? _intent;
  MeetupDateFilter? _openDate;
  MeetupDateFilter? _historyDate;

  // The filters survive a switch between My meetings and Requested meetings.
  @override
  bool get wantKeepAlive => true;

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
    String cursor, {
    IntentType? intent,
    DateTime? from,
    DateTime? to,
  }) async {
    final result = await ref
        .read(meetupServiceProvider)
        .listMyMeetups(
          hostedCursor: widget.isHosted ? cursor : null,
          requestedCursor: widget.isHosted ? null : cursor,
          intent: intent,
          from: from,
          to: to,
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

  void _clearFilters() => setState(() {
    _intent = null;
    _openDate = null;
    _historyDate = null;
  });

  @override
  Widget build(BuildContext context) {
    // Required by the keep-alive mixin.
    super.build(context);
    return Stack(
      children: [
        Column(
          children: [
            _SubTabSelector(controller: _subTabs),
            Expanded(
              child: TabBarView(
                controller: _subTabs,
                physics: _noSwipeInsideAppShell,
                children: [
                  _buildTab(_isOpen, widget.emptyState, past: false),
                  _buildTab(_isHistory, widget.historyEmptyState, past: true),
                ],
              ),
            ),
          ],
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: IntentFilterFab(
            selected: _intent,
            onSelect: (picked) => setState(() => _intent = picked),
          ),
        ),
      ],
    );
  }

  Widget _buildTab(
    bool Function(Meetup) filter,
    Widget emptyState, {
    required bool past,
  }) {
    final date = past ? _historyDate : _openDate;
    return Column(
      children: [
        MeetupDateFilterBar(
          selected: date,
          past: past,
          clearable: true,
          onChanged: (picked) => setState(() {
            if (past) {
              _historyDate = picked;
            } else {
              _openDate = picked;
            }
          }),
        ),
        Expanded(
          child: _intent == null && date == null
              ? _buildList(
                  filter: filter,
                  emptyState: emptyState,
                  items: widget.initialItems,
                  nextCursor: widget.initialNextCursor,
                  hasMore: widget.initialHasMore,
                  loadMore: _loadMore,
                )
              : _buildFilteredList(filter, date, past: past),
        ),
      ],
    );
  }

  /// The server does this filtering, because the list is paged and matches
  /// may be on pages not fetched yet. Open and History still split here.
  Widget _buildFilteredList(
    bool Function(Meetup) filter,
    MeetupDateFilter? date, {
    required bool past,
  }) {
    final range = date?.range(DateTime.now(), past: past);
    final key = (intent: _intent, from: range?.from, to: range?.to);
    return ref
        .watch(filteredMyMeetupsProvider(key))
        .when(
          loading: () =>
              _MyMeetupsSkeleton(withAction: widget.isHosted && !past),
          error: (error, _) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              LoadFailedState(
                failure: LoadFailure.of(error),
                onRetry: () => ref.invalidate(filteredMyMeetupsProvider(key)),
              ),
            ],
          ),
          data: (result) => _buildList(
            // Fresh pagination state for each filter.
            key: ValueKey(key),
            filter: filter,
            emptyState: _NoFilterMatches(onClear: _clearFilters),
            items: widget.isHosted ? result.hosted : result.requested,
            nextCursor: widget.isHosted
                ? result.hostedNextCursor
                : result.requestedNextCursor,
            hasMore: widget.isHosted
                ? result.hostedHasMore
                : result.requestedHasMore,
            loadMore: (cursor) => _loadMore(
              cursor,
              intent: key.intent,
              from: key.from,
              to: key.to,
            ),
          ),
        );
  }

  Widget _buildList({
    Key? key,
    required bool Function(Meetup) filter,
    required Widget emptyState,
    required List<Meetup> items,
    required String? nextCursor,
    required bool hasMore,
    required Future<({List<Meetup> items, String? nextCursor, bool hasMore})>
    Function(String cursor)
    loadMore,
  }) {
    return PaginatedMeetupList(
      key: key,
      items: items.where(filter).toList(),
      nextCursor: nextCursor,
      hasMore: hasMore,
      loadMore: (cursor) async {
        final next = await loadMore(cursor);
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

class _NoFilterMatches extends StatelessWidget {
  const _NoFilterMatches({required this.onClear});

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const EmptySection(
          icon: AppIcons.calendar,
          title: 'No meetups match these filters',
        ),
        const SizedBox(height: 12),
        SecondaryButton(
          key: const Key('clear-filters'),
          label: 'Clear filters',
          height: 44,
          onPressed: onClear,
        ),
      ],
    );
  }
}
