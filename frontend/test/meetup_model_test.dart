import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';

Meetup _meetup({required DateTime windowStart, required DateTime windowEnd}) =>
    Meetup(
      id: 'meetup-1',
      hostUserId: 'host-1',
      hostFullName: 'Grace Hopper',
      hostTrustLevel: 2,
      intent: IntentType.coffee,
      windowStart: windowStart,
      windowEnd: windowEnd,
      locationLat: 6.9271,
      locationLng: 79.8612,
      locationLabel: 'Colombo Fort Cafe',
      capacity: 4,
      acceptedCount: 0,
      status: MeetupStatus.open,
      createdAt: DateTime.now(),
    );

void main() {
  group('formatMeetupWindow / Meetup.formattedWindow (ADR-016)', () {
    test('today, same AM/PM period — period shown once, at the end', () {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day, 15, 0);
      final end = DateTime(now.year, now.month, now.day, 17, 0);

      expect(formatMeetupWindow(start, end), 'Today, 3:00–5:00 PM');
      expect(
        _meetup(windowStart: start, windowEnd: end).formattedWindow,
        'Today, 3:00–5:00 PM',
      );
    });

    test('a future date — shows the abbreviated month and day', () {
      final start = DateTime(2026, 8, 22, 18, 0);
      final end = DateTime(2026, 8, 22, 20, 0);

      expect(formatMeetupWindow(start, end), 'Aug 22, 6:00–8:00 PM');
    });

    test(
      'crossing AM/PM within the same day — both times carry their own suffix',
      () {
        final start = DateTime(2026, 8, 22, 11, 30);
        final end = DateTime(2026, 8, 22, 13, 30);

        expect(formatMeetupWindow(start, end), 'Aug 22, 11:30 AM–1:30 PM');
      },
    );

    test(
      'crossing midnight — allowed (ADR-016 doesn\'t require same-day), '
      'both times carry their own AM/PM suffix, date shown is the start date',
      () {
        final start = DateTime(2026, 8, 22, 22, 0);
        final end = DateTime(2026, 8, 23, 1, 0);

        expect(formatMeetupWindow(start, end), 'Aug 22, 10:00 PM–1:00 AM');
      },
    );

    test('noon and midnight format as 12, not 0', () {
      final noon = DateTime(2026, 8, 22, 12, 0);
      final afternoon = DateTime(2026, 8, 22, 13, 0);
      expect(formatMeetupWindow(noon, afternoon), 'Aug 22, 12:00–1:00 PM');

      final midnight = DateTime(2026, 8, 22, 0, 0);
      final earlyMorning = DateTime(2026, 8, 22, 1, 0);
      expect(
        formatMeetupWindow(midnight, earlyMorning),
        'Aug 22, 12:00–1:00 AM',
      );
    });
  });
}
