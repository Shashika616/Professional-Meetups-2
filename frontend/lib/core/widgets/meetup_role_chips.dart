import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';

/// Who is hosting, and where the viewer stands, on every meetup card.
///
/// One widget for all of them (Happening Now, Waiting for review,
/// Cancelled, the Active Meetups rows) so the answer is in the same words
/// and colours wherever a meetup appears: a person reading Home should
/// never have to open a meetup to learn whether it is theirs, whether they
/// are going, or who is running it.
///
/// Reads only what the server already sends (`isHostedByMe`,
/// `myRequestStatus`, `hostFullName`); nothing here is inferred.
///
/// [concluded] switches the wording to the past tense for a meetup that is
/// over or called off (the review and cancelled decks): "YOU HOSTED" and
/// "YOU JOINED" rather than "YOU'RE HOSTING" and "YOU'RE IN", because a
/// present-tense chip on a finished meetup reads as if it were still on.
class MeetupRoleChips extends StatelessWidget {
  const MeetupRoleChips({
    super.key,
    required this.meetup,
    this.compact = false,
    this.showHostName = true,
    this.concluded = false,
  });

  final Meetup meetup;

  /// Smaller type and tighter padding, for the compact list rows.
  final bool compact;

  /// Whether the host chip carries the host's name. A card whose title is
  /// already the host's name only needs the HOST tag.
  final bool showHostName;

  /// Past tense: the meetup has ended or was cancelled.
  final bool concluded;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[];
    if (meetup.isHostedByMe) {
      chips.add(
        _RoleChip(
          icon: AppIcons.star,
          label: concluded ? 'You hosted' : 'You\'re hosting',
          tone: AppPalette.brandGreen,
          compact: compact,
        ),
      );
    } else {
      final host = meetup.hostFullName;
      final named = showHostName && host != null && host.isNotEmpty;
      chips.add(
        _RoleChip(
          icon: AppIcons.person,
          label: switch ((concluded, named)) {
            (true, true) => 'Hosted by ${host!}',
            (true, false) => 'Hosted',
            (false, true) => 'Host · ${host!}',
            (false, false) => 'Host',
          },
          tone: AppPalette.textSecondary,
          compact: compact,
        ),
      );
      final status = meetup.myRequestStatus;
      if (status != null) {
        final (label, icon, tone) = switch (status) {
          MeetupRequestStatus.accepted => (
            concluded ? 'You joined' : 'You\'re in',
            AppIcons.checkCircle,
            AppPalette.verified,
          ),
          // A request nobody answered before the meetup ended or was
          // called off is no longer pending anything.
          MeetupRequestStatus.pending => (
            concluded ? 'Not answered' : 'Request pending',
            AppIcons.hourglass,
            AppPalette.gold,
          ),
          // Never "rejected" or "declined" where the requester reads it.
          // A muted tone: it is a fact about fit, not a fault to flag.
          MeetupRequestStatus.rejected => (
            'Not this time',
            AppIcons.explore,
            AppPalette.textSecondary,
          ),
          MeetupRequestStatus.withdrawn => (
            'Withdrawn',
            AppIcons.undo,
            AppPalette.textSecondary,
          ),
        };
        chips.add(
          _RoleChip(icon: icon, label: label, tone: tone, compact: compact),
        );
      }
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: chips,
    );
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({
    required this.icon,
    required this.label,
    required this.tone,
    required this.compact,
  });

  final String icon;
  final String label;
  final Color tone;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: compact
          ? const EdgeInsets.fromLTRB(6, 3, 7, 3)
          : const EdgeInsets.fromLTRB(7, 4, 9, 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: tone.withValues(alpha: 0.12),
        border: Border.all(color: tone.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(icon, size: compact ? 11 : 12, color: tone),
          SizedBox(width: compact ? 3 : 4),
          Text(
            label,
            style: TextStyle(
              color: tone,
              fontSize: compact ? 9 : 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.9,
            ),
          ),
        ],
      ),
    );
  }
}
