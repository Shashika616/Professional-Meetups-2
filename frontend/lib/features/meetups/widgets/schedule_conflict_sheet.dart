import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/meetup_role_chips.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/meetups/meetup_detail_page.dart';

/// Shown when hosting or joining is refused because the person is already
/// committed to a meetup in that window (the server's
/// [MeetupScheduleConflictException]). Names the meetup in the way, says
/// when it ends, and offers the two ways forward the rule allows: wait, or
/// open that meetup and cancel it (or the request to it) there — the
/// detail page already owns those actions and their confirmations, so this
/// sheet sends the person to them rather than duplicating them.
///
/// One sheet for both the schedule flow and the join paths, so the rule is
/// explained in the same words wherever it applies.
Future<void> showScheduleConflictSheet(
  BuildContext context, {
  required MeetupScheduleConflictException error,
}) {
  return showModalBottomSheet<void>(
    context: context,
    // Sized to its content and scrollable past the default 9/16 cap, so a
    // long place name or a small screen never pushes the actions off the
    // bottom.
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppPalette.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _ScheduleConflictSheet(conflict: error.conflict),
  );
}

class _ScheduleConflictSheet extends StatelessWidget {
  const _ScheduleConflictSheet({required this.conflict});

  final Meetup conflict;

  @override
  Widget build(BuildContext context) {
    final hosting = conflict.isHostedByMe;
    final accepted = conflict.myRequestStatus == MeetupRequestStatus.accepted;
    final end = conflict.windowEnd;
    final endsAt = end == null ? '' : ' at ${formatMeetupTime(end)}';

    final headline = hosting
        ? 'You\'re already hosting a meetup at that time'
        : accepted
        ? 'You\'re already in a meetup at that time'
        : 'You\'ve already asked to join a meetup at that time';
    final wayOut = hosting
        ? 'cancel that meetup'
        : accepted
        ? 'withdraw from it'
        : 'cancel that request';

    // Bottom inset by hand: showModalBottomSheet's useSafeArea covers the
    // top only, and a three-button navigation bar would sit over I'LL WAIT.
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        10,
        20,
        16 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppPalette.hairline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'One meetup at a time',
            style: TextStyle(
              color: AppPalette.gold,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            headline,
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w800,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 14),
          FlatCard(
            radius: 18,
            padding: const EdgeInsets.all(14),
            tint: AppPalette.gold.withValues(alpha: 0.08),
            border: AppPalette.gold.withValues(alpha: 0.35),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  conflict.intentLabel,
                  style: TextStyle(
                    color: AppPalette.gold,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 6),
                MeetupRoleChips(meetup: conflict),
                const SizedBox(height: 8),
                _Line(AppIcons.clock, conflict.formattedWindow),
                if (conflict.locationLabel case final label?
                    when label.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  _Line(AppIcons.pin, label),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Wait until it ends$endsAt, or $wayOut to free the time.',
            style: TextStyle(
              color: AppPalette.textSecondary,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),
          PrimaryButton(
            label: 'Open that meetup',
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => MeetupDetailPage(meetupId: conflict.id),
                ),
              );
            },
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'I\'ll wait',
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.icon, this.text);

  final String icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: AppIcon(icon, size: 14, color: AppPalette.textSecondary),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: AppPalette.textPrimary, fontSize: 13),
          ),
        ),
      ],
    );
  }
}
