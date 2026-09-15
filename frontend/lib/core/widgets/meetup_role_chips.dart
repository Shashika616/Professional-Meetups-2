import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';

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
class MeetupRoleChips extends StatelessWidget {
  const MeetupRoleChips({
    super.key,
    required this.meetup,
    this.compact = false,
    this.showHostName = true,
  });

  final Meetup meetup;

  /// Smaller type and tighter padding, for the compact list rows.
  final bool compact;

  /// Whether the host chip carries the host's name. A card whose title is
  /// already the host's name only needs the HOST tag.
  final bool showHostName;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[];
    if (meetup.isHostedByMe) {
      chips.add(
        _RoleChip(
          icon: Icons.star_rounded,
          label: 'YOU\'RE HOSTING',
          tone: AppPalette.brandGreen,
          compact: compact,
        ),
      );
    } else {
      final host = meetup.hostFullName;
      chips.add(
        _RoleChip(
          icon: Icons.person_rounded,
          label: showHostName && host != null && host.isNotEmpty
              ? 'HOST · ${host.toUpperCase()}'
              : 'HOST',
          tone: AppPalette.textSecondary,
          compact: compact,
        ),
      );
      final status = meetup.myRequestStatus;
      if (status != null) {
        final (label, icon, tone) = switch (status) {
          MeetupRequestStatus.accepted => (
            'YOU\'RE IN',
            Icons.check_circle_rounded,
            AppPalette.verified,
          ),
          MeetupRequestStatus.pending => (
            'REQUEST PENDING',
            Icons.hourglass_top_rounded,
            AppPalette.gold,
          ),
          MeetupRequestStatus.rejected => (
            'NOT SELECTED',
            Icons.cancel_rounded,
            AppPalette.danger,
          ),
          MeetupRequestStatus.withdrawn => (
            'WITHDRAWN',
            Icons.undo_rounded,
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

  final IconData icon;
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
          Icon(icon, size: compact ? 11 : 12, color: tone),
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
