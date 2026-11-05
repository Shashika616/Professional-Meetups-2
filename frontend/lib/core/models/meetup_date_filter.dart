/// Which days a meetup list shows.
///
/// Boundaries are worked out on the device, so "today" follows the viewer's
/// clock. The server filters on them, because these lists are paged and a
/// filter applied here would miss what has not loaded yet.
class MeetupDateFilter {
  const MeetupDateFilter._(this.kind, [this.day]);

  static const today = MeetupDateFilter._(MeetupDateKind.today);
  static const thisWeek = MeetupDateFilter._(MeetupDateKind.thisWeek);

  /// Exactly one chosen day.
  factory MeetupDateFilter.on(DateTime day) => MeetupDateFilter._(
    MeetupDateKind.day,
    DateTime(day.year, day.month, day.day),
  );

  final MeetupDateKind kind;
  final DateTime? day;

  /// The range as [from, to). [past] looks back for the History tab, so a
  /// week there is today and the six days before it.
  ({DateTime from, DateTime to}) range(DateTime now, {bool past = false}) {
    final start = DateTime(now.year, now.month, now.day);
    DateTime plus(DateTime d, int days) =>
        DateTime(d.year, d.month, d.day + days);
    return switch (kind) {
      MeetupDateKind.today => (from: start, to: plus(start, 1)),
      MeetupDateKind.thisWeek =>
        past
            ? (from: plus(start, -6), to: plus(start, 1))
            : (from: start, to: plus(start, 7)),
      MeetupDateKind.day => (from: day!, to: plus(day!, 1)),
    };
  }

  @override
  bool operator ==(Object other) =>
      other is MeetupDateFilter && other.kind == kind && other.day == day;

  @override
  int get hashCode => Object.hash(kind, day);
}

enum MeetupDateKind { today, thisWeek, day }
