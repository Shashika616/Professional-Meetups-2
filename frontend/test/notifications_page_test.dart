import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/features/meetups/meetup_detail_page.dart';
import 'package:professional_connections_platform/features/notifications/notifications_page.dart';

import 'support/scripted_meetup_service.dart';

AppNotification _notification({
  String id = 'n1',
  String title = 'New join request',
  String body = 'Ada wants to join your coffee meetup',
  String type = 'join_request',
  String meetupId = 'meetup-1',
  required DateTime createdAt,
}) => AppNotification(
  id: id,
  title: title,
  body: body,
  type: type,
  meetupId: meetupId,
  createdAt: createdAt,
);

Widget _appWith(ScriptedMeetupService service) => ProviderScope(
  overrides: [meetupServiceProvider.overrideWithValue(service)],
  child: const MaterialApp(home: NotificationsPage()),
);

void main() {
  group('date grouping', () {
    // now is injected so this does not fail depending on when it runs — a
    // date-bucketing function tested against the real clock breaks at
    // midnight.
    final now = DateTime(2026, 9, 9, 14, 30);

    test('buckets into TODAY, YESTERDAY, then explicit dates', () {
      final groups = groupNotificationsByDay([
        _notification(id: 'a', createdAt: DateTime(2026, 9, 9, 9, 5)),
        _notification(id: 'b', createdAt: DateTime(2026, 9, 8, 22, 0)),
        _notification(id: 'c', createdAt: DateTime(2026, 9, 8, 8, 0)),
        _notification(id: 'd', createdAt: DateTime(2026, 9, 5, 11, 0)),
      ], now: now);

      expect(groups.map((g) => g.label).toList(), [
        'TODAY',
        'YESTERDAY',
        '2026/09/05',
      ]);
      // The two same-day rows land in one group rather than two headings.
      expect(groups[1].notifications.map((n) => n.id).toList(), ['b', 'c']);
    });

    test('a notification later the same day is still TODAY', () {
      final groups = groupNotificationsByDay([
        _notification(createdAt: DateTime(2026, 9, 9, 23, 59)),
      ], now: now);
      expect(groups.single.label, 'TODAY');
    });

    test('midnight yesterday is YESTERDAY, not two days ago', () {
      final groups = groupNotificationsByDay([
        _notification(createdAt: DateTime(2026, 9, 8, 0, 0)),
      ], now: now);
      expect(groups.single.label, 'YESTERDAY');
    });

    test('empty in, empty out', () {
      expect(groupNotificationsByDay(const [], now: now), isEmpty);
    });

    test('times are 24-hour and zero-padded', () {
      expect(formatNotificationTime(DateTime(2026, 9, 9, 9, 5)), '09:05');
      expect(formatNotificationTime(DateTime(2026, 9, 9, 21, 40)), '21:40');
    });
  });

  testWidgets('renders the notifications under their day headings', (
    tester,
  ) async {
    final service = ScriptedMeetupService()
      ..notifications = [
        _notification(createdAt: DateTime.now()),
        _notification(
          id: 'n2',
          title: 'Request accepted',
          body: 'The host accepted your request',
          type: 'request_accepted',
          createdAt: DateTime.now().subtract(const Duration(days: 1)),
        ),
      ];

    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('YESTERDAY'), findsOneWidget);
    expect(find.text('New join request'), findsOneWidget);
    expect(find.text('Request accepted'), findsOneWidget);
  });

  testWidgets('an empty history says so rather than showing a blank page', (
    tester,
  ) async {
    final service = ScriptedMeetupService()..notifications = const [];

    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    expect(find.text('All quiet for now'), findsOneWidget);
    expect(find.textContaining('last 7 days'), findsOneWidget);
  });

  testWidgets('a failed load offers a retry rather than an empty list', (
    tester,
  ) async {
    final service = ScriptedMeetupService()
      ..notificationsError = Exception('offline');

    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't load"), findsOneWidget);
    expect(find.text('TRY AGAIN'), findsOneWidget);
    // The empty state must not be shown for a failure — they mean different
    // things and only one of them is the user's fault to wait out.
    expect(find.text('Nothing yet.'), findsNothing);

    service.notificationsError = null;
    service.notifications = [_notification(createdAt: DateTime.now())];
    await tester.tap(find.text('TRY AGAIN'));
    await tester.pumpAndSettle();

    expect(find.text('New join request'), findsOneWidget);
  });

  testWidgets('tapping a meetup notification opens that meetup', (
    tester,
  ) async {
    final service = ScriptedMeetupService()
      ..notifications = [_notification(createdAt: DateTime.now())];

    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('New join request'));
    await tester.pumpAndSettle();

    expect(find.byType(MeetupDetailPage), findsOneWidget);
  });

  testWidgets('a notification with no meetup is inert rather than opening a '
      'blank detail page', (tester) async {
    final service = ScriptedMeetupService()
      ..notifications = [
        _notification(
          title: 'Something general',
          type: 'some_future_type',
          meetupId: '',
          createdAt: DateTime.now(),
        ),
      ];

    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Something general'));
    await tester.pumpAndSettle();

    expect(find.byType(MeetupDetailPage), findsNothing);
    expect(find.byType(NotificationsPage), findsOneWidget);
  });
}
