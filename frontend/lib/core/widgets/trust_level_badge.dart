import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// A compact "L{n}" pill — the one place trust level is rendered as a
/// badge, so meetup cards and the request-management screen (frontend/
/// meetup-scheduling-PLAN.md Step 8) don't each invent their own trust-level
/// display. Mirrors the "L$trustLevel" format `ProfilePage`'s stats row
/// already uses.
class TrustLevelBadge extends StatelessWidget {
  const TrustLevelBadge({super.key, required this.trustLevel});

  final int trustLevel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: AppPalette.verified.withValues(alpha: 0.10),
        border: Border.all(color: AppPalette.verified.withValues(alpha: 0.30)),
      ),
      // "L3 Trust", not a bare "L3": on a card between a name and a star
      // rating a lone letter-digit reads as a code; the word says what the
      // number is about.
      child: Text(
        'L$trustLevel Trust',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
          color: AppPalette.verified,
        ),
      ),
    );
  }
}
