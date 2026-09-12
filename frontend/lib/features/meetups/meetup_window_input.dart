import 'package:flutter/material.dart' show TimeOfDay;

/// Pure, widget-free rules for the Schedule flow's timing step. Kept
/// separate from `schedule_flow.dart` so every rule here is unit-testable
/// against a fixed clock, with no widget tree and no wall-clock dependency
/// — the timing step itself is a thin shell over these.
///
/// # WHY STRICT 24-HOUR TYPED ENTRY
///
/// The previous step used Flutter's dial picker forced into 24-hour mode.
/// Three problems, all reported from real use:
///
///  1. The dial is fiddly on a phone and there was no obvious way to just
///     type a time. `showTimePicker` does have a keyboard toggle, but it's
///     an icon in the dialog's corner that nobody found.
///  2. Nothing checked that the START was still in the future. Pick today
///     with a time already gone by, and the flow let you through Location
///     and Review before the backend refused it at the very end
///     (`window_start can't be in the past`). The check belongs where the
///     time is entered.
///  3. An end time numerically before the start was flatly rejected, so a
///     22:00–01:00 meetup could not be scheduled at all. In 24-hour time,
///     00 after 23 is unambiguously the next day — so that's what it means.
///
/// A typed `HH:MM` field with a strict 00:00–23:59 domain removes the
/// dial, removes AM/PM as a source of error, and makes the midnight
/// rollover rule expressible without a second date field.

/// Parses strict 24-hour `HH:MM` (or the bare four digits `HHMM`, which
/// is what the field's formatter holds internally) into a [TimeOfDay].
///
/// Returns null for anything incomplete or out of domain: fewer than four
/// digits, an hour above 23, a minute above 59. Deliberately does NOT
/// accept `24:00` — in this system midnight is `00:00` of the next day,
/// and the rollover rule in [resolveMeetupWindow] is what expresses that.
TimeOfDay? parseTime24h(String raw) {
  final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length != 4) return null;
  final hour = int.parse(digits.substring(0, 2));
  final minute = int.parse(digits.substring(2, 4));
  if (hour > 23 || minute > 59) return null;
  return TimeOfDay(hour: hour, minute: minute);
}

/// Formats a [TimeOfDay] as strict 24-hour `HH:MM` — always two digits
/// each, never a locale-dependent AM/PM form. The one text form this step
/// shows a time in, so what the user typed is exactly what they read back.
String formatTime24h(TimeOfDay time) =>
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}';

/// Why a [ResolvedMeetupWindow] can't be submitted. `none` is the only
/// value under which [ResolvedMeetupWindow.start]/[ResolvedMeetupWindow.end]
/// should ever be sent anywhere.
enum MeetupWindowProblem {
  none,

  /// `to` is the same minute as `from`. Under the rollover rule that
  /// would mean a 24-hour meetup, which is never what was intended.
  endEqualsStart,

  /// The resolved start is already behind the clock. Only possible when
  /// the picked date is today — the date picker refuses earlier dates.
  startInPast,
}

/// The outcome of [resolveMeetupWindow]: the concrete window plus the two
/// facts the UI needs to explain it (whether the end rolled over to the
/// next day, and whether something makes it unsubmittable).
class ResolvedMeetupWindow {
  const ResolvedMeetupWindow({
    required this.start,
    required this.end,
    required this.endsNextDay,
    required this.problem,
  });

  final DateTime start;
  final DateTime end;

  /// True when `to` was numerically at or before `from` and so was read
  /// as the following day — the fact the UI must state out loud, since
  /// a user who mistyped 15:00 as 05:00 should see "ends tomorrow" and
  /// catch it, not discover a 14-hour meetup later.
  final bool endsNextDay;

  final MeetupWindowProblem problem;

  bool get isValid => problem == MeetupWindowProblem.none;
}

/// Turns a picked date and two 24-hour times into a concrete window,
/// applying the rules above. [now] is injected, never read from the
/// clock here, so this is deterministic under test.
///
/// The rollover: if `to` is at or before `from` on [date], the end lands
/// on the day after. The next-day date is built from calendar components
/// (`day + 1`, which `DateTime` normalises across month and year ends)
/// rather than `add(Duration(days: 1))`, because a Duration is 24 elapsed
/// hours and lands one hour off across a DST change — the calendar day
/// after is what "tomorrow at 01:00" means.
///
/// The past check compares against [now] truncated to the minute, so the
/// current minute is still selectable: someone tapping through at 14:30:45
/// who typed 14:30 meant "now", and the backend's own five-minute grace
/// period covers the request latency from there.
ResolvedMeetupWindow resolveMeetupWindow({
  required DateTime date,
  required TimeOfDay from,
  required TimeOfDay to,
  required DateTime now,
}) {
  final start = DateTime(
    date.year,
    date.month,
    date.day,
    from.hour,
    from.minute,
  );
  final sameDayEnd = DateTime(
    date.year,
    date.month,
    date.day,
    to.hour,
    to.minute,
  );

  final endsNextDay = !sameDayEnd.isAfter(start);
  final end = endsNextDay
      ? DateTime(date.year, date.month, date.day + 1, to.hour, to.minute)
      : sameDayEnd;

  final MeetupWindowProblem problem;
  if (from.hour == to.hour && from.minute == to.minute) {
    problem = MeetupWindowProblem.endEqualsStart;
  } else if (start.isBefore(
    DateTime(now.year, now.month, now.day, now.hour, now.minute),
  )) {
    problem = MeetupWindowProblem.startInPast;
  } else {
    problem = MeetupWindowProblem.none;
  }

  return ResolvedMeetupWindow(
    start: start,
    end: end,
    endsNextDay: endsNextDay,
    problem: problem,
  );
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// The DATE card's text: `Today · Fri 11 Sep`, `Tomorrow · Sat 12 Sep`, or
/// `Fri 25 Sep 2026` further out. A raw ISO `2026-09-11` is what the card
/// showed before — machine-friendly, not something anyone says out loud.
String formatPickedDate(DateTime date, {required DateTime now}) {
  final core =
      '${_weekdays[date.weekday - 1]} ${date.day} '
      '${_months[date.month - 1]}';
  if (_sameDay(date, now)) return 'Today · $core';
  if (_sameDay(date, DateTime(now.year, now.month, now.day + 1))) {
    return 'Tomorrow · $core';
  }
  return '$core ${date.year}';
}

/// One line describing a resolved window, for the summary under the
/// fields: `22:00 → 01:00 (+1) · 3 h`. The `(+1)` is the next-day marker
/// airlines and timetables use; the duration is the sanity check that
/// catches a mistyped hour before it becomes a 14-hour meetup.
String describeWindow(ResolvedMeetupWindow window) {
  final from = formatTime24h(TimeOfDay.fromDateTime(window.start));
  final to = formatTime24h(TimeOfDay.fromDateTime(window.end));
  final minutes = window.end.difference(window.start).inMinutes;
  final h = minutes ~/ 60;
  final m = minutes % 60;
  final duration = m == 0 ? '$h h' : (h == 0 ? '$m min' : '$h h $m min');
  return '$from → $to${window.endsNextDay ? ' (+1)' : ''} · $duration';
}
