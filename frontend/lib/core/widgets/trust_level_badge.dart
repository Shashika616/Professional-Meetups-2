import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/widgets/app_tag.dart';

/// A compact "L{n} Trust" pill — the one place trust level is rendered as a
/// badge, so meetup cards and the request-management screen (frontend/
/// meetup-scheduling-PLAN.md Step 8) don't each invent their own
/// trust-level display.
///
/// Built on [AppTag] since the 2026-10 redesign, for the same contrast
/// reason as [MeetupStatusBadge]: this used to paint `AppPalette.verified`
/// as 10px text on a 10%-alpha wash of itself, which on the light theme is
/// about 2.4:1.
class TrustLevelBadge extends StatelessWidget {
  const TrustLevelBadge({super.key, required this.trustLevel, this.onSurface});

  final int trustLevel;

  /// See [AppTag.onSurface].
  final Color? onSurface;

  @override
  Widget build(BuildContext context) {
    // "L3 Trust", not a bare "L3": on a card between a name and a star
    // rating a lone letter-digit reads as a code; the word says what the
    // number is about.
    return AppTag(
      'L$trustLevel Trust',
      tone: AppTone.success,
      onSurface: onSurface,
    );
  }
}
