import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// Fetches one more page after [items], starting from [cursor].
///
/// Returns the next page's items plus the cursor after them; a null cursor
/// means there is nothing further. Kept as a plain callback rather than a
/// service reference so this widget stays unaware of WHICH list it is paging
/// — the two call sites page different RPCs with different cursor shapes.
typedef LoadMoreMeetups =
    Future<({List<Meetup> items, String? nextCursor, bool hasMore})> Function(
      String cursor,
    );

/// The infinite-scroll + pull-to-refresh list every paginated meetup view
/// uses.
///
/// # WHY THIS EXISTS
///
/// This exact widget was hand-written twice — once in `matches_page.dart`
/// and once in `my_meetups_page.dart`, the latter with a comment
/// acknowledging it was a copy rather than a shared base. Both carried the
/// same ScrollController, the same 400px near-bottom threshold, the same
/// `_hasMore`/`_loadingMore` guards, and the same subtle
/// `didUpdateWidget`-resets-on-a-new-page logic. Two copies of a piece of
/// state machinery that fiddly is two chances to fix a bug in one of them.
///
/// # PULL-TO-REFRESH IS PART OF THE WIDGET, NOT THE CALLER
///
/// Both former copies relied on their PAGE to wrap them in a RefreshIndicator,
/// and each page did it differently (the browse page refreshed by re-reading
/// the device location; Events did not offer it at all). Owning it here means
/// every list that scrolls down also pulls down, which is the whole "graceful
/// at both ends" requirement — a caller cannot forget half of it.
class PaginatedMeetupList extends StatefulWidget {
  const PaginatedMeetupList({
    super.key,
    required this.items,
    required this.nextCursor,
    required this.hasMore,
    required this.loadMore,
    required this.onRefresh,
    required this.itemBuilder,
    required this.emptyMessage,
    this.emptyState,
    this.padding = const EdgeInsets.fromLTRB(20, 4, 20, 100),
    this.shrinkWrap = false,
    this.physics,
    this.outerScrollController,
  });

  /// The FIRST page. A new instance (not just new contents) is treated as a
  /// fresh first page and resets accumulated state — see [didUpdateWidget].
  final List<Meetup> items;
  final String? nextCursor;
  final bool hasMore;

  final LoadMoreMeetups loadMore;

  /// Invoked by the pull-to-refresh gesture. The caller re-fetches page one
  /// however it needs to; this widget then picks the new page up through
  /// [items] changing.
  final Future<void> Function() onRefresh;

  /// Builds one row.
  ///
  /// [previous] is the item immediately above, or null for the first — it is
  /// what lets a caller start a new section when some property changes
  /// (Happening Soon groups by week this way) without this widget needing to
  /// know anything about grouping, and without the caller having to track
  /// the accumulated pages itself.
  final Widget Function(BuildContext context, Meetup meetup, Meetup? previous)
  itemBuilder;

  /// Shown when there is nothing to list. [emptyState] wins when both are
  /// given; [emptyMessage] is the plain-text fallback for callers whose
  /// empty case is genuinely just a sentence.
  final String emptyMessage;
  final Widget? emptyState;
  final EdgeInsets padding;

  /// Set when this list is nested inside another scrollable (Home's single
  /// ListView), where it must not scroll independently. In that mode the
  /// parent owns the scroll gesture and pull-to-refresh (see [build]), and
  /// infinite-scroll is driven by [outerScrollController].
  final bool shrinkWrap;
  final ScrollPhysics? physics;

  /// The controller of the scrollable that ACTUALLY scrolls when this list
  /// is shrink-wrapped — i.e. the parent's.
  ///
  /// # WHY THIS IS NOT OPTIONAL IN PRACTICE, THOUGH IT IS NULLABLE
  ///
  /// A shrink-wrapped list with NeverScrollableScrollPhysics never scrolls
  /// itself, so its own ScrollController is attached to nothing and its
  /// `.position` is never meaningful. The original code still added the
  /// near-bottom listener to that internal controller and left a doc comment
  /// claiming "the parent owns infinite-scroll too" — but nothing ever
  /// bridged the parent's scroll position back down here, so
  /// `_maybeLoadNextPage` could not fire at all. Home's nearby-meetups list
  /// was capped at page one, silently: no error, no indicator, no crash.
  ///
  /// Passing the outer controller is what makes the claim true. It stays
  /// nullable because the non-shrink-wrapped callers (EventsPage's sub-tabs)
  /// legitimately have no outer controller — they scroll themselves — and
  /// this parameter is meaningless for them.
  ///
  /// NOT owned by this widget: whoever created it disposes it. See [dispose].
  final ScrollController? outerScrollController;

  @override
  State<PaginatedMeetupList> createState() => PaginatedMeetupListState();
}

/// # THIS WAS PUBLIC FOR A TEST SEAM THAT IS GONE
///
/// It was public so a widget test could call `loadNextPageForTest()` and
/// skip "synthesising a 400px scroll in a fake viewport". That seam is
/// deleted, and its removal is part of the fix rather than tidying: testing
/// through it proved `loadMore` works when something calls it, while the
/// thing that was supposed to call it was never wired at all. The test
/// passed for a year's worth of confidence in a list that could not paginate
/// (docs/plans/07-happening-soon-pagination-fix.md).
///
/// The replacement tests synthesise the scroll, which turns out to be a few
/// lines, and they fail when the wiring is removed — verified by control
/// run. The class stays public only because renaming it back to private is
/// churn with no benefit; nothing outside this file references it.
class PaginatedMeetupListState extends State<PaginatedMeetupList> {
  late List<Meetup> _items;
  String? _nextCursor;
  bool _hasMore = false;
  bool _loadingMore = false;

  /// Created unconditionally but ATTACHED only on the non-shrink-wrapped
  /// path — see [_listeningController] for which one actually drives
  /// pagination, and [dispose] for why ownership matters.
  final _scrollController = ScrollController();

  /// The controller whose position decides when to fetch the next page.
  ///
  /// Shrink-wrapped: the parent's, because this list does not scroll.
  /// Otherwise: this list's own, unchanged from before.
  ScrollController get _listeningController =>
      widget.shrinkWrap && widget.outerScrollController != null
      ? widget.outerScrollController!
      : _scrollController;

  /// Bumped every time the first page is replaced. An in-flight
  /// [_loadNextPage] captures it before awaiting and discards its result if
  /// it changed while the fetch was out — see [_loadNextPage].
  int _generation = 0;

  /// How close to the bottom triggers the next fetch. Carried over unchanged
  /// from both former copies: far enough out that the next page usually
  /// arrives before the user reaches the end, close enough that it is not
  /// fetching pages nobody will look at.
  static const _nearBottomThreshold = 400.0;

  @override
  void initState() {
    super.initState();
    _resetFromWidget();
    _listeningController.addListener(_maybeLoadNextPage);
    _checkAfterLayout();
  }

  /// Checks the near-bottom condition once after the frame this widget first
  /// appears in, on the outer-controller path only.
  ///
  /// # WHY A LISTENER ALONE IS NOT ENOUGH HERE
  ///
  /// A listener only ever fires on a scroll that happens AFTER it is
  /// attached. When this list is nested far down a lazily-laid-out parent
  /// (Home's ListView), it is not mounted until the parent scrolls it into
  /// range — so the scroll that revealed it is the one scroll the listener
  /// cannot see. Land at or near the bottom in one motion (a fling, a
  /// restored scroll position, or simply a short page) and pagination would
  /// sit there waiting for a scroll event that never comes.
  ///
  /// Deliberately NOT done on the internal-controller path: a
  /// non-shrink-wrapped list whose first page does not fill the viewport
  /// would immediately fetch page two, which is a behaviour change for
  /// EventsPage rather than a fix. That path is left exactly as it was.
  void _checkAfterLayout() {
    if (!widget.shrinkWrap || widget.outerScrollController == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _maybeLoadNextPage();
    });
  }

  void _resetOnNewFirstPage(PaginatedMeetupList oldWidget) {
    // Identity, not equality: this catches the case where the widget stays
    // mounted while its first page is refetched in place (Riverpod's default
    // skipLoadingOnRefresh keeps `.when()` in `data:` with the stale value
    // while a new one loads, so a fresh page arrives without ever passing
    // through `loading:`/`initState`). Without this, a page-2 fetch already
    // in flight would append onto a now-stale page one.
    if (!identical(widget.items, oldWidget.items)) {
      setState(_resetFromWidget);
    }
  }

  void _resetFromWidget() {
    _items = List.of(widget.items);
    _nextCursor = widget.nextCursor;
    _hasMore = widget.hasMore;
    _loadingMore = false;
    // Orphans any fetch still in flight against the page being replaced.
    // Clearing `_loadingMore` alone is not enough: this State object stays
    // mounted across a refetch-in-place, so the awaiting `_loadNextPage`
    // resumes with `mounted` still true and would happily append the OLD
    // page's continuation onto the NEW first page — cursors from two
    // different queries, silently interleaved.
    _generation++;
  }

  @override
  void dispose() {
    // Remove our listener from whichever controller we attached it to. When
    // that is the OUTER controller this is load-bearing rather than tidy:
    // it belongs to the page and outlives this widget (Home rebuilds this
    // section on every intent-filter change while the page keeps scrolling),
    // so a listener left behind would keep calling into a disposed State.
    _listeningController.removeListener(_maybeLoadNextPage);
    // Only ever the one we created. Disposing the outer controller here
    // would break the page that owns it the moment this list unmounts.
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PaginatedMeetupList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-point the listener if the caller swapped controllers (or switched
    // shrink-wrap mode) without remounting. Cheap, and it is the difference
    // between pagination quietly dying after a rebuild and continuing to
    // work.
    if (oldWidget.outerScrollController != widget.outerScrollController ||
        oldWidget.shrinkWrap != widget.shrinkWrap) {
      final previous =
          oldWidget.shrinkWrap && oldWidget.outerScrollController != null
          ? oldWidget.outerScrollController!
          : _scrollController;
      previous.removeListener(_maybeLoadNextPage);
      _listeningController.addListener(_maybeLoadNextPage);
      _checkAfterLayout();
    }
    _resetOnNewFirstPage(oldWidget);
  }

  void _maybeLoadNextPage() {
    if (!_hasMore || _loadingMore) return;
    final controller = _listeningController;
    // A controller with no attached scrollable has no position to read. That
    // is the state the internal one is permanently in on the shrink-wrapped
    // path, and it is also a transient state during teardown.
    if (!controller.hasClients) return;
    if (controller.position.pixels >=
        controller.position.maxScrollExtent - _nearBottomThreshold) {
      _loadNextPage();
    }
  }

  Future<void> _loadNextPage() async {
    if (!_hasMore || _loadingMore || _nextCursor == null) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final next = await widget.loadMore(_nextCursor!);
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = [..._items, ...next.items];
        _nextCursor = next.nextCursor;
        _hasMore = next.hasMore;
        _loadingMore = false;
      });
    } catch (_) {
      // Best-effort, carried over from both former copies: the current page
      // stays visible and scrolling again retries. Deliberately no toast —
      // this fires from a scroll listener, not from anything the user asked
      // for, and a toast they did not trigger is worse than a page that
      // simply stops growing.
      if (!mounted || generation != _generation) return;
      setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // A list SHORTER than the viewport (an empty one, or a single short
    // page) does not scroll under the default physics, and a RefreshIndicator
    // has no overscroll to detect on a scrollable that cannot scroll — so
    // pull-to-refresh would silently not work in exactly the states a user is
    // most likely to pull in. AlwaysScrollableScrollPhysics is what makes the
    // "kept inside a scrollable" decision below actually buy the gesture.
    //
    // `widget.physics ??`, not an override: shrink-wrap mode passes
    // NeverScrollableScrollPhysics deliberately (the parent scrolls), and
    // that must win.
    final physics = widget.physics ?? const AlwaysScrollableScrollPhysics();

    final list = _items.isEmpty
        ? ListView(
            controller: widget.shrinkWrap ? null : _scrollController,
            shrinkWrap: widget.shrinkWrap,
            physics: physics,
            padding: widget.padding,
            children: [
              // Kept inside a scrollable rather than a bare Center so the
              // pull-to-refresh gesture still works with nothing to show —
              // an empty list is exactly when a user is most likely to pull.
              if (widget.emptyState case final emptyState?)
                emptyState
              else
                SizedBox(
                  height: widget.shrinkWrap ? 160 : 300,
                  child: Center(
                    child: Text(
                      widget.emptyMessage,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppPalette.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
            ],
          )
        : ListView.builder(
            controller: widget.shrinkWrap ? null : _scrollController,
            shrinkWrap: widget.shrinkWrap,
            physics: physics,
            padding: widget.padding,
            itemCount: _items.length + (_hasMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= _items.length) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              }
              return widget.itemBuilder(
                context,
                _items[index],
                index == 0 ? null : _items[index - 1],
              );
            },
          );

    // Nested mode: the parent scrollable already owns both gestures, and a
    // RefreshIndicator here would be unreachable (no scroll of its own to
    // detect an overscroll on) while quietly swallowing the parent's.
    if (widget.shrinkWrap) return list;
    return RefreshIndicator(onRefresh: widget.onRefresh, child: list);
  }
}
