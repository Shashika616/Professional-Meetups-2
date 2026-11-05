import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup_date_filter.dart';
import 'package:professional_connections_platform/features/meetups/widgets/intent_filter_fab.dart';
import 'package:professional_connections_platform/features/meetups/widgets/meetup_date_filter_bar.dart';

void main() {
  group('date ranges', () {
    final now = DateTime(2026, 11, 6, 15, 30);

    test('today is the whole local day', () {
      final r = MeetupDateFilter.today.range(now);
      expect(r.from, DateTime(2026, 11, 6));
      expect(r.to, DateTime(2026, 11, 7));
    });

    test('this week is today and the next six days', () {
      final r = MeetupDateFilter.thisWeek.range(now);
      expect(r.from, DateTime(2026, 11, 6));
      expect(r.to, DateTime(2026, 11, 13));
    });

    test('in History the week looks back', () {
      final r = MeetupDateFilter.thisWeek.range(now, past: true);
      expect(r.from, DateTime(2026, 10, 31));
      expect(r.to, DateTime(2026, 11, 7));
    });

    test('a picked date is that day only, across a month end', () {
      final r = MeetupDateFilter.on(DateTime(2026, 12, 31, 9)).range(now);
      expect(r.from, DateTime(2026, 12, 31));
      expect(r.to, DateTime(2027, 1, 1));
    });

    test('the same day is the same filter, so it shares one cached result', () {
      expect(
        MeetupDateFilter.on(DateTime(2026, 11, 8, 9)),
        MeetupDateFilter.on(DateTime(2026, 11, 8, 18)),
      );
    });
  });

  Widget host(Widget child) => MaterialApp(
    home: Scaffold(
      body: Align(alignment: Alignment.bottomRight, child: child),
    ),
  );

  group('intent button', () {
    testWidgets('one tap shows All first, then every intent', (tester) async {
      await tester.pumpWidget(
        host(IntentFilterFab(selected: null, onSelect: (_) {})),
      );
      await tester.tap(find.byKey(const Key('intent-fab')));
      await tester.pumpAndSettle();

      final all = tester.getTopLeft(find.byKey(const ValueKey('intent-all')));
      for (final intent in IntentType.values) {
        final row = find.byKey(ValueKey('intent-${intent.name}'));
        expect(row, findsOneWidget);
        expect(tester.getTopLeft(row).dy, greaterThan(all.dy));
      }
    });

    testWidgets('closed, it is only an icon, even with an intent chosen', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(IntentFilterFab(selected: IntentType.lunch, onSelect: (_) {})),
      );
      expect(find.text(IntentType.lunch.label), findsNothing);
    });

    testWidgets('the close button shuts the dial', (tester) async {
      await tester.pumpWidget(
        host(IntentFilterFab(selected: null, onSelect: (_) {})),
      );
      await tester.tap(find.byKey(const Key('intent-fab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('intent-fab-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('intent-all')), findsNothing);
    });

    testWidgets('choosing returns the intent, and All returns null', (
      tester,
    ) async {
      final picked = <IntentType?>[];
      await tester.pumpWidget(
        host(IntentFilterFab(selected: IntentType.lunch, onSelect: picked.add)),
      );
      await tester.tap(find.byKey(const Key('intent-fab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('intent-all')));
      await tester.pumpAndSettle();
      expect(picked, [null]);
    });

    testWidgets('tapping outside closes it without changing anything', (
      tester,
    ) async {
      final picked = <IntentType?>[];
      await tester.pumpWidget(
        host(IntentFilterFab(selected: null, onSelect: picked.add)),
      );
      await tester.tap(find.byKey(const Key('intent-fab')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('intent-all')), findsNothing);
      expect(picked, isEmpty);
    });

    testWidgets('the list scrolls at large text on a small screen', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 480),
            textScaler: TextScaler.linear(2),
          ),
          child: host(IntentFilterFab(selected: null, onSelect: (_) {})),
        ),
      );
      await tester.tap(find.byKey(const Key('intent-fab')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('date row', () {
    final now = DateTime(2026, 11, 6);

    Future<List<MeetupDateFilter?>> tapChip(
      WidgetTester tester,
      String key, {
      required MeetupDateFilter? selected,
      bool clearable = false,
    }) async {
      final seen = <MeetupDateFilter?>[];
      await tester.pumpWidget(
        host(
          MeetupDateFilterBar(
            selected: selected,
            clearable: clearable,
            onChanged: seen.add,
            now: now,
          ),
        ),
      );
      await tester.tap(find.byKey(Key(key)));
      await tester.pump();
      return seen;
    }

    testWidgets('a chip selects its range', (tester) async {
      expect(
        await tapChip(
          tester,
          'date-today',
          selected: MeetupDateFilter.thisWeek,
        ),
        [MeetupDateFilter.today],
      );
    });

    testWidgets('Home keeps a filter on when the chip is tapped again', (
      tester,
    ) async {
      expect(
        await tapChip(tester, 'date-week', selected: MeetupDateFilter.thisWeek),
        isEmpty,
      );
    });

    testWidgets('Events clears it when the chip is tapped again', (
      tester,
    ) async {
      expect(
        await tapChip(
          tester,
          'date-today',
          selected: MeetupDateFilter.today,
          clearable: true,
        ),
        [null],
      );
    });

    Future<DatePickerDialog> openCalendar(
      WidgetTester tester, {
      required bool past,
    }) async {
      await tester.pumpWidget(
        host(
          MeetupDateFilterBar(
            selected: null,
            past: past,
            clearable: true,
            onChanged: (_) {},
            now: now,
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('date-pick')));
      await tester.pumpAndSettle();
      return tester.widget<DatePickerDialog>(find.byType(DatePickerDialog));
    }

    testWidgets('upcoming lists cannot pick a past date', (tester) async {
      final dialog = await openCalendar(tester, past: false);
      expect(dialog.firstDate, now);
      expect(dialog.lastDate.isAfter(now), isTrue);
    });

    testWidgets('History can pick past dates but not future ones', (
      tester,
    ) async {
      final dialog = await openCalendar(tester, past: true);
      expect(dialog.lastDate, now);
      expect(dialog.firstDate.isBefore(now), isTrue);
    });

    testWidgets('History calls the week the last 7 days', (tester) async {
      await tester.pumpWidget(
        host(
          MeetupDateFilterBar(selected: null, past: true, onChanged: (_) {}),
        ),
      );
      expect(find.text('Last 7 days'), findsOneWidget);
      expect(find.text('This week'), findsNothing);
    });
  });
}
