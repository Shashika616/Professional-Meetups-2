import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// A compact, color-coded lifecycle-status pill (ADR-016 addendum,
/// 2026-08-20) — every card that renders a [Meetup] shows this, additively
/// alongside whatever accepted-count/request-status text it already shows.
/// Mirrors [TrustLevelBadge]'s shape (`core/widgets/trust_level_badge.dart`),
/// the one existing compact-pill convention in this codebase.
class MeetupStatusBadge extends StatelessWidget {
  const MeetupStatusBadge({super.key, required this.status});

  final MeetupStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      MeetupStatus.open => ('OPEN', AppPalette.verified),
      MeetupStatus.full => ('FULL', AppPalette.candyBlue),
      MeetupStatus.cancelled => ('CANCELLED', AppPalette.danger),
      MeetupStatus.completed => ('COMPLETED', AppPalette.textSecondary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
          color: color,
        ),
      ),
    );
  }
}
