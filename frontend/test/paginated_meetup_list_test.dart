import 'dart:async' show Completer;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/widgets/paginated_meetup_list.dart';

/// The infinite-scroll + pull-to-refresh machinery, tested once.
///
/// # WHERE THIS FILE CAME FROM
///
/// Two hand-written copies of this widget used to live inside
/// `matches_page.dart` and `my_meetups_page.dart`, each with its own
/// pagination tests. Those pages are now [EventsPage] and
/// [HappeningSoonSection], and both delegate to the single
/// [PaginatedMeetupList]. So the pagination tests belong here, against the
/// widget itself, rather than being run twice through two pages that no
/// longer own the behaviour.
///
/// Every scroll-driven case below was ported from the deleted
/// `matches_page_test.dart`'s "cursor pagination" group; the shrink-wrap
/// group is new, because nesting is new.
Meetup _meetup(String id) => Meetup(
  id: id,
  hostUserId: 'host-1',
  hostFullName: 'Grace Hopper',
  hostTrustLevel: 3,
  intent: IntentType.coffee,
  windowStart: DateTime(2026, 9, 7, 10),
  windowEnd: DateTime(2026, 9, 7, 12),
  locationLat: 6.9271,
  locationLng: 79.8612,
  locationLabel: 'Colombo Fort Cafe',
  capacity: 4,
  acceptedCount: 0,
  status: MeetupStatus.open,
  createdAt: DateTime(2026, 9, 1),
);

/// A tall, findable row so `drag()` has real scroll extent to work with and
/// each item is identifiable by text.
Widget _row(BuildContext context, Meetup meetup, Meetup? previous) =>
    SizedBox(height: 120, child: Center(child: Text(meetup.id)));

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('infinite scroll', () {
    testWidgets(
      'scrolling near the bottom with hasMore=true fetches the next page '
      'via the returned cursor and appends its items',
      (tester) async {
        final cursors = <String>[];
        await tester.pumpWidget(
          _host(
            PaginatedMeetupList(
              items: List.generate(10, (i) => _meetup('meetup-$i')),
              nextCursor: 'cursor-1',
              hasMore: true,
              loadMore: (cursor) async {
                cursors.add(cursor);
                return (
                  items: [_meetup('meetup-page-2')],
                  nextCursor: null,
                  hasMore: false,
                );
              },
              onRefresh: () async {},
              itemBuilder: _row,
              emptyMessage: 'nothing here',
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(cursors, isEmpty);
        expect(find.text('meetup-page-2'), findsNothing);

        await tester.drag(find.byType(ListView), const Offset(0, -6000));
        await tester.pumpAndSettle();

        expect(cursors, ['cursor-1']);
        expect(find.text('meetup-page-2'), findsOneWidget);
      },
    );

    testWidgets(
      'scrolling near the bottom with hasMore=false does not fetch anything',
      (tester) async {
        var calls = 0;
        await tester.pumpWidget(
          _host(
            PaginatedMeetupList(
              items: List.generate(10, (i) => _meetup('meetup-$i')),
              nextCursor: null,
              hasMore: false,
              loadMore: (cursor) async {
                calls++;
                return (items: <Meetup>[], nextCursor: null, hasMore: false);
              },
              onRefresh: () async {},
              itemBuilder: _row,
              emptyMessage: 'nothing here',
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.drag(find.byType(ListView), const Offset(0, -6000));
        await tester.pumpAndSettle();

        expect(calls, 0);
      },
    );

    testWidgets(
      'a first page replaced while a next-page fetch is still in flight '
      'discards the stale result instead of appending it onto the new page '
      '— the didUpdateWidget identity reset',
      (tester) async {
        final gate = Completer<void>();
        Widget build(List<Meetup> items) => _host(
          PaginatedMeetupList(
            items: items,
            nextCursor: 'cursor-1',
            hasMore: true,
            loadMore: (cursor) async {
              await gate.future;
              return (
                items: [_meetup('stale-page-2')],
                nextCursor: null,
                hasMore: false,
              );
            },
            onRefresh: () async {},
            itemBuilder: _row,
            emptyMessage: 'nothing here',
          ),
        );

        await tester.pumpWidget(
          build(List.generate(10, (i) => _meetup('a-$i'))),
        );
        // Not pumpAndSettle anywhere in this test: `hasMore` is true
        // throughout, and the footer's indeterminate CircularProgressIndicator
        // never settles on its own.
        await tester.pump();

        // Put a page-2 fetch in flight, blocked on a gate we control rather
        // than racing a real delay.
        await tester.drag(find.byType(ListView), const Offset(0, -6000));
        await tester.pump();

        // A brand-new first page arrives (a refetch landing in place, which
        // is exactly what Riverpod's skipLoadingOnRefresh produces).
        await tester.pumpWidget(
          build(List.generate(10, (i) => _meetup('b-$i'))),
        );
        await tester.pump();

        // Asserted on the LAST row: the list is still scrolled to its
        // bottom, so the early rows of either page are virtualized away and
        // prove nothing.
        expect(find.text('b-9'), findsOneWidget);
        expect(find.text('a-9'), findsNothing);

        gate.complete();
        await tester.pump();
        await tester.pump();

        expect(
          find.text('stale-page-2'),
          findsNothing,
          reason:
              'the in-flight fetch belonged to the previous first page and '
              'must not append onto the replacement',
        );
      },
    );

    testWidgets(
      'a failed next-page fetch is swallowed — the current page stays '
      'visible and _loadingMore actually clears, proven by a later scroll '
      'being allowed to retry rather than blocked',
      (tester) async {
        var calls = 0;
        await tester.pumpWidget(
          _host(
            PaginatedMeetupList(
              items: List.generate(10, (i) => _meetup('meetup-$i')),
              nextCursor: 'cursor-1',
              hasMore: true,
              loadMore: (cursor) async {
                calls++;
                throw Exception('network error');
              },
              onRefresh: () async {},
              itemBuilder: _row,
              emptyMessage: 'nothing here',
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.drag(find.byType(ListView), const Offset(0, -6000));
        // Not pumpAndSettle: `hasMore` deliberately stays true after a
        // failed fetch, and the footer's indeterminate spinner never
        // settles on its own. A single drag's own incremental pointer-move
        // events can retrigger the listener more than once against a fake
        // that fails instantly, so the count is not pinned to an exact
        // number here — only that it moved.
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        final afterFirstDrag = calls;
        expect(afterFirstDrag, greaterThanOrEqualTo(1));
        // The page is still rendered, not blanked or crashed by the failed
        // fetch. Checked on the LAST row rather than the first: the list is
        // scrolled to its bottom here, and ListView.builder has virtualized
        // the early rows away — their absence would be normal, so asserting
        // on them would prove nothing either way.
        expect(find.text('meetup-9'), findsOneWidget);

        // Scroll up, then back down — a repeat drag to an unchanged
        // position would not re-fire the listener at all, so this genuinely
        // re-triggers the load. If _loadingMore were left stuck true, the
        // retry would be silently blocked and the count would stop moving.
        await tester.drag(find.byType(ListView), const Offset(0, 200));
        await tester.pump();
        await tester.drag(find.byType(ListView), const Offset(0, -6000));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          calls,
          greaterThan(afterFirstDrag),
          reason:
              '_loadingMore must not be left permanently stuck true by a '
              'failed fetch',
        );
      },
    );
  });

  group('pull-to-refresh', () {
    testWidgets('a pull gesture calls onRefresh', (tester) async {
      var refreshes = 0;
      await tester.pumpWidget(
        _host(
          PaginatedMeetupList(
            items: List.generate(10, (i) => _meetup('meetup-$i')),
            nextCursor: null,
            hasMore: false,
            loadMore: (cursor) async =>
                (items: <Meetup>[], nextCursor: null, hasMore: false),
            onRefresh: () async => refreshes++,
            itemBuilder: _row,
            emptyMessage: 'nothing here',
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(refreshes, 1);
    });

    testWidgets(
      'an EMPTY list still pulls to refresh — the empty state lives inside '
      'a scrollable precisely so the gesture survives, and an empty list is '
      'when a user is most likely to pull',
      (tester) async {
        var refreshes = 0;
        await tester.pumpWidget(
          _host(
            PaginatedMeetupList(
              items: const [],
              nextCursor: null,
              hasMore: false,
              loadMore: (cursor) async =>
                  (items: <Meetup>[], nextCursor: null, hasMore: false),
              onRefresh: () async => refreshes++,
              itemBuilder: _row,
              emptyMessage: 'nothing here',
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('nothing here'), findsOneWidget);

        await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();

        expect(refreshes, 1);
      },
    );
  });

  group('shrink-wrap (nested inside another scrollable, as on Home)', () {
    testWidgets(
      'no RefreshIndicator of its own — one here would be unreachable and '
      'would swallow the parent scrollable\'s gesture',
      (tester) async {
        await tester.pumpWidget(
          _host(
            ListView(
              children: [
                PaginatedMeetupList(
                  items: [_meetup('meetup-0')],
                  nextCursor: null,
                  hasMore: false,
                  loadMore: (cursor) async =>
                      (items: <Meetup>[], nextCursor: null, hasMore: false),
                  onRefresh: () async {},
                  itemBuilder: _row,
                  emptyMessage: 'nothing here',
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('meetup-0'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(PaginatedMeetupList),
            matching: find.byType(RefreshIndicator),
          ),
          findsNothing,
        );
      },
    );

    /// # THE TEST THAT SHOULD HAVE EXISTED FIRST
    ///
    /// This replaces one that called `loadNextPageForTest()` — the escape
    /// hatch — and therefore only ever proved that `loadMore` works when
    /// something calls it. Nothing proved that anything ever DOES call it in
    /// shrink-wrap mode, and nothing did: the widget attached its listener
    /// to an internal ScrollController that, in this mode, is handed to no
    /// scrollable at all. Home's nearby-meetups list was stuck on page one,
    /// silently.
    ///
    /// So this drives the OUTER controller — the one that actually scrolls
    /// in production — and never touches the escape hatch. That distinction
    /// is the whole reason the bug shipped.
    testWidgets(
      'scrolling the OUTER list past the threshold loads the next page — '
      'the real production trigger, not the load function in isolation',
      (tester) async {
        final cursors = <String>[];
        final outer = ScrollController();
        addTearDown(outer.dispose);

        await tester.pumpWidget(
          _host(
            ListView(
              controller: outer,
              children: [
                // Tall enough that the outer list has real scroll extent to
                // cross the 400px near-bottom threshold with.
                const SizedBox(height: 1200),
                PaginatedMeetupList(
                  items: List.generate(6, (i) => _meetup('meetup-$i')),
                  nextCursor: 'cursor-1',
                  hasMore: true,
                  loadMore: (cursor) async {
                    cursors.add(cursor);
                    return (
                      items: [_meetup('meetup-page-2')],
                      nextCursor: null,
                      hasMore: false,
                    );
                  },
                  onRefresh: () async {},
                  itemBuilder: _row,
                  emptyMessage: 'nothing here',
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  outerScrollController: outer,
                ),
              ],
            ),
          ),
        );
        await tester.pump();

        expect(
          cursors,
          isEmpty,
          reason: 'nothing should load before scrolling',
        );

        // Drive the outer controller the way a real drag would.
        outer.jumpTo(outer.position.maxScrollExtent);
        await tester.pump();
        await tester.pump();

        expect(
          cursors,
          ['cursor-1'],
          reason:
              'crossing the outer list\'s near-bottom threshold must trigger '
              'the next page — this is what was dead on Home',
        );
        expect(find.text('meetup-page-2'), findsOneWidget);
      },
    );

    testWidgets(
      'the LISTENER path works too, with the list already mounted and well '
      'away from the bottom — proves pagination does not depend on the '
      'post-frame check happening to catch it',
      (tester) async {
        final cursors = <String>[];
        final outer = ScrollController();
        addTearDown(outer.dispose);

        await tester.pumpWidget(
          _host(
            ListView(
              controller: outer,
              children: [
                const SizedBox(height: 1200),
                PaginatedMeetupList(
                  items: List.generate(6, (i) => _meetup('meetup-$i')),
                  nextCursor: 'cursor-1',
                  hasMore: true,
                  loadMore: (cursor) async {
                    cursors.add(cursor);
                    return (
                      items: [_meetup('meetup-page-2')],
                      nextCursor: null,
                      hasMore: false,
                    );
                  },
                  onRefresh: () async {},
                  itemBuilder: _row,
                  emptyMessage: 'nothing here',
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  outerScrollController: outer,
                ),
              ],
            ),
          ),
        );
        await tester.pump();

        // Step 1: scroll far enough to MOUNT the nested list (Home's outer
        // ListView lays out lazily, so it does not exist before this), but
        // stay well outside the 400px near-bottom threshold so the
        // post-frame check cannot fire.
        outer.jumpTo(700);
        await tester.pump();
        await tester.pump();
        expect(
          find.byType(PaginatedMeetupList),
          findsOneWidget,
          reason:
              'the nested list must be mounted before this test means anything',
        );
        expect(cursors, isEmpty, reason: 'still far from the bottom');

        // Step 2: now scroll to the bottom. The list is already mounted, so
        // ONLY the scroll listener can trigger this.
        outer.jumpTo(outer.position.maxScrollExtent);
        await tester.pump();
        await tester.pump();

        expect(cursors, ['cursor-1']);
        expect(find.text('meetup-page-2'), findsOneWidget);
      },
    );

    testWidgets(
      'a scroll that stays far from the bottom loads nothing — the threshold '
      'is a real check, not "any scroll event triggers a fetch"',
      (tester) async {
        final cursors = <String>[];
        final outer = ScrollController();
        addTearDown(outer.dispose);

        await tester.pumpWidget(
          _host(
            ListView(
              controller: outer,
              children: [
                const SizedBox(height: 4000),
                PaginatedMeetupList(
                  items: List.generate(6, (i) => _meetup('meetup-$i')),
                  nextCursor: 'cursor-1',
                  hasMore: true,
                  loadMore: (cursor) async {
                    cursors.add(cursor);
                    return (
                      items: <Meetup>[],
                      nextCursor: null,
                      hasMore: false,
                    );
                  },
                  onRefresh: () async {},
                  itemBuilder: _row,
                  emptyMessage: 'nothing here',
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  outerScrollController: outer,
                ),
              ],
            ),
          ),
        );
        await tester.pump();

        outer.jumpTo(100);
        await tester.pump();
        await tester.pump();

        expect(cursors, isEmpty);
      },
    );

    testWidgets(
      'the widget does not dispose a controller it does not own — the outer '
      'one belongs to the page, which may outlive this list (a filter change '
      'rebuilds the section while Home keeps scrolling)',
      (tester) async {
        final outer = ScrollController();
        addTearDown(outer.dispose);

        Widget build({required bool showList}) => _host(
          ListView(
            controller: outer,
            children: [
              const SizedBox(height: 600),
              if (showList)
                PaginatedMeetupList(
                  items: [_meetup('meetup-0')],
                  nextCursor: null,
                  hasMore: false,
                  loadMore: (cursor) async =>
                      (items: <Meetup>[], nextCursor: null, hasMore: false),
                  onRefresh: () async {},
                  itemBuilder: _row,
                  emptyMessage: 'nothing here',
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  outerScrollController: outer,
                ),
            ],
          ),
        );

        await tester.pumpWidget(build(showList: true));
        await tester.pumpAndSettle();

        // Unmount the list; the page (and its controller) stay.
        await tester.pumpWidget(build(showList: false));
        await tester.pumpAndSettle();

        // Still usable. If the list had disposed it, this throws.
        expect(outer.hasClients, isTrue);
        outer.jumpTo(50);
        await tester.pump();
        expect(outer.offset, 50);
      },
    );
  });
}
