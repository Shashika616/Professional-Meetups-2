import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/features/meetups/meetup_window_input.dart';

void main() {
  group('parseTime24h — strict 00:00–23:59', () {
    test('accepts HH:MM and bare HHMM identically', () {
      expect(parseTime24h('21:30'), const TimeOfDay(hour: 21, minute: 30));
      expect(parseTime24h('2130'), const TimeOfDay(hour: 21, minute: 30));
    });

    test('accepts both ends of the domain', () {
      expect(parseTime24h('00:00'), const TimeOfDay(hour: 0, minute: 0));
      expect(parseTime24h('23:59'), const TimeOfDay(hour: 23, minute: 59));
    });

    test(
      'rejects hour 24 — midnight is 00:00 of the next day, never 24:00',
      () {
        expect(parseTime24h('24:00'), isNull);
      },
    );

    test('rejects out-of-domain hour and minute', () {
      expect(parseTime24h('25:00'), isNull);
      expect(parseTime24h('12:60'), isNull);
      expect(parseTime24h('99:99'), isNull);
    });

    test('rejects anything incomplete rather than guessing', () {
      expect(parseTime24h(''), isNull);
      expect(parseTime24h('9'), isNull);
      expect(parseTime24h('9:30'), isNull);
      expect(parseTime24h('093'), isNull);
    });
  });

  group('formatTime24h', () {
    test('always two digits each, no AM/PM', () {
      expect(formatTime24h(const TimeOfDay(hour: 0, minute: 0)), '00:00');
      expect(formatTime24h(const TimeOfDay(hour: 9, minute: 5)), '09:05');
      expect(formatTime24h(const TimeOfDay(hour: 23, minute: 59)), '23:59');
    });
  });

  group('resolveMeetupWindow', () {
    // A fixed "now" well inside the day, so tests are independent of the
    // wall clock they happen to run under.
    final now = DateTime(2026, 9, 11, 10, 30, 45);
    final today = DateTime(2026, 9, 11);

    test('an ordinary same-day window resolves as typed', () {
      final r = resolveMeetupWindow(
        date: today,
        from: const TimeOfDay(hour: 15, minute: 0),
        to: const TimeOfDay(hour: 17, minute: 0),
        now: now,
      );
      expect(r.isValid, isTrue);
      expect(r.endsNextDay, isFalse);
      expect(r.start, DateTime(2026, 9, 11, 15, 0));
      expect(r.end, DateTime(2026, 9, 11, 17, 0));
    });

    test('00 after 23 is the next day: 22:00–01:00 ends tomorrow at 01:00', () {
      final r = resolveMeetupWindow(
        date: today,
        from: const TimeOfDay(hour: 22, minute: 0),
        to: const TimeOfDay(hour: 1, minute: 0),
        now: now,
      );
      expect(r.isValid, isTrue);
      expect(r.endsNextDay, isTrue);
      expect(r.start, DateTime(2026, 9, 11, 22, 0));
      expect(r.end, DateTime(2026, 9, 12, 1, 0));
      expect(r.end.isAfter(r.start), isTrue);
    });

    test(
      'an end at 00:00 exactly is midnight tonight, i.e. tomorrow 00:00',
      () {
        final r = resolveMeetupWindow(
          date: today,
          from: const TimeOfDay(hour: 23, minute: 0),
          to: const TimeOfDay(hour: 0, minute: 0),
          now: now,
        );
        expect(r.isValid, isTrue);
        expect(r.endsNextDay, isTrue);
        expect(r.end, DateTime(2026, 9, 12, 0, 0));
      },
    );

    test(
      'rollover crosses a month end by calendar day, not by adding hours',
      () {
        final r = resolveMeetupWindow(
          date: DateTime(2026, 9, 30),
          from: const TimeOfDay(hour: 23, minute: 0),
          to: const TimeOfDay(hour: 1, minute: 0),
          now: DateTime(2026, 9, 30, 12),
        );
        expect(r.end, DateTime(2026, 10, 1, 1, 0));
      },
    );

    test('rollover crosses a year end', () {
      final r = resolveMeetupWindow(
        date: DateTime(2026, 12, 31),
        from: const TimeOfDay(hour: 23, minute: 30),
        to: const TimeOfDay(hour: 0, minute: 30),
        now: DateTime(2026, 12, 31, 12),
      );
      expect(r.end, DateTime(2027, 1, 1, 0, 30));
    });

    test(
      'the same minute for both is rejected — that would be a 24h meetup',
      () {
        final r = resolveMeetupWindow(
          date: today,
          from: const TimeOfDay(hour: 15, minute: 0),
          to: const TimeOfDay(hour: 15, minute: 0),
          now: now,
        );
        expect(r.isValid, isFalse);
        expect(r.problem, MeetupWindowProblem.endEqualsStart);
      },
    );

    test('a start already behind the clock today is rejected', () {
      final r = resolveMeetupWindow(
        date: today,
        from: const TimeOfDay(hour: 9, minute: 0),
        to: const TimeOfDay(hour: 11, minute: 0),
        now: now, // 10:30
      );
      expect(r.isValid, isFalse);
      expect(r.problem, MeetupWindowProblem.startInPast);
    });

    test('the current minute is still allowed — seconds are not held against '
        'the user', () {
      final r = resolveMeetupWindow(
        date: today,
        from: const TimeOfDay(hour: 10, minute: 30),
        to: const TimeOfDay(hour: 12, minute: 0),
        now: now, // 10:30:45
      );
      expect(r.isValid, isTrue);
    });

    test('one minute behind the clock is not allowed', () {
      final r = resolveMeetupWindow(
        date: today,
        from: const TimeOfDay(hour: 10, minute: 29),
        to: const TimeOfDay(hour: 12, minute: 0),
        now: now,
      );
      expect(r.problem, MeetupWindowProblem.startInPast);
    });

    test('a past time of day on a FUTURE date is fine — only today can be '
        'in the past', () {
      final r = resolveMeetupWindow(
        date: DateTime(2026, 9, 12),
        from: const TimeOfDay(hour: 9, minute: 0),
        to: const TimeOfDay(hour: 11, minute: 0),
        now: now,
      );
      expect(r.isValid, isTrue);
    });

    test('a same-minute pair is reported as equal, not as past, even when it '
        'is also in the past — the more actionable message wins', () {
      final r = resolveMeetupWindow(
        date: today,
        from: const TimeOfDay(hour: 8, minute: 0),
        to: const TimeOfDay(hour: 8, minute: 0),
        now: now,
      );
      expect(r.problem, MeetupWindowProblem.endEqualsStart);
    });
  });

  group('formatPickedDate', () {
    final now = DateTime(2026, 9, 11, 14, 0); // a Friday

    test('today and tomorrow are named, with the weekday kept', () {
      expect(
        formatPickedDate(DateTime(2026, 9, 11), now: now),
        'Today · Fri 11 Sep',
      );
      expect(
        formatPickedDate(DateTime(2026, 9, 12), now: now),
        'Tomorrow · Sat 12 Sep',
      );
    });

    test('anything further out carries the year', () {
      expect(
        formatPickedDate(DateTime(2026, 9, 25), now: now),
        'Fri 25 Sep 2026',
      );
    });

    test('tomorrow is computed by calendar day across a month end', () {
      expect(
        formatPickedDate(DateTime(2026, 10, 1), now: DateTime(2026, 9, 30, 23)),
        'Tomorrow · Thu 1 Oct',
      );
    });
  });

  group('describeWindow', () {
    final now = DateTime(2026, 9, 11, 10);
    test('same-day window with whole hours', () {
      final r = resolveMeetupWindow(
        date: DateTime(2026, 9, 11),
        from: const TimeOfDay(hour: 15, minute: 0),
        to: const TimeOfDay(hour: 17, minute: 0),
        now: now,
      );
      expect(describeWindow(r), '15:00 → 17:00 · 2 h');
    });

    test('next-day window carries the +1 marker', () {
      final r = resolveMeetupWindow(
        date: DateTime(2026, 9, 11),
        from: const TimeOfDay(hour: 22, minute: 0),
        to: const TimeOfDay(hour: 1, minute: 30),
        now: now,
      );
      expect(describeWindow(r), '22:00 → 01:30 (+1) · 3 h 30 min');
    });

    test('sub-hour window shows minutes only', () {
      final r = resolveMeetupWindow(
        date: DateTime(2026, 9, 11),
        from: const TimeOfDay(hour: 15, minute: 0),
        to: const TimeOfDay(hour: 15, minute: 45),
        now: now,
      );
      expect(describeWindow(r), '15:00 → 15:45 · 45 min');
    });
  });
}
