import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/models/meetup_date_filter.dart';
import 'package:professional_connections_platform/core/widgets/app_chip.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';

/// Today, This week and a calendar for one chosen day.
///
/// [past] turns it round for the History tab: the calendar reaches back
/// instead of forward, and the week becomes the last seven days.
class MeetupDateFilterBar extends StatelessWidget {
  const MeetupDateFilterBar({
    super.key,
    required this.selected,
    required this.onChanged,
    this.past = false,
    this.clearable = false,
    this.now,
  });

  /// Null means no date filter, which only a [clearable] bar can have.
  final MeetupDateFilter? selected;
  final ValueChanged<MeetupDateFilter?> onChanged;
  final bool past;

  /// Whether tapping the selected chip removes the filter. Home always has
  /// one, so there a tap on the selected chip does nothing.
  final bool clearable;

  /// For tests. Defaults to the device clock.
  final DateTime? now;

  /// How far ahead of today the calendar reaches.
  static const _daysAhead = 365;

  /// How far back History's calendar reaches.
  static const _daysBack = 365 * 5;

  void _tap(MeetupDateFilter filter) {
    if (filter != selected) {
      onChanged(filter);
    } else if (clearable) {
      onChanged(null);
    }
  }

  Future<void> _pick(BuildContext context) async {
    final clock = now ?? DateTime.now();
    final today = DateTime(clock.year, clock.month, clock.day);
    final first = past
        ? today.subtract(const Duration(days: _daysBack))
        : today;
    final last = past ? today : today.add(const Duration(days: _daysAhead));
    final chosen = selected?.day;
    final initial =
        chosen == null || chosen.isBefore(first) || chosen.isAfter(last)
        ? today
        : chosen;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
    if (picked != null) onChanged(MeetupDateFilter.on(picked));
  }

  @override
  Widget build(BuildContext context) {
    final day = selected?.day;
    return SizedBox(
      height: 44,
      width: double.infinity,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            _chip(
              key: const Key('date-today'),
              label: 'Today',
              selected: selected == MeetupDateFilter.today,
              onTap: () => _tap(MeetupDateFilter.today),
            ),
            const SizedBox(width: 7),
            _chip(
              key: const Key('date-week'),
              label: past ? 'Last 7 days' : 'This week',
              selected: selected == MeetupDateFilter.thisWeek,
              onTap: () => _tap(MeetupDateFilter.thisWeek),
            ),
            const SizedBox(width: 7),
            _chip(
              key: const Key('date-pick'),
              label: day == null ? 'Pick date' : formatMeetupDay(day),
              icon: AppIcons.calendar,
              selected: day != null,
              onTap: () => _pick(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip({
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onTap,
    String? icon,
  }) {
    return Padding(
      // The chip is drawn at 32; this makes the rest of the row tap area.
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: AppChip(
        key: key,
        label: label,
        icon: icon,
        selected: selected,
        onTap: onTap,
      ),
    );
  }
}
