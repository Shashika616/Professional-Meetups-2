import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';

/// What an [AppTag] is saying, which decides its colour.
///
/// Tone is semantic, never decorative — do not reach for [AppTone.warning]
/// because a screen needs some yellow. Every tag of a given tone on every
/// screen must mean the same kind of thing, or the colour stops carrying
/// information and becomes noise the user learns to ignore.
enum AppTone {
  /// Neutral-but-notable: a category ("Coffee", "Networking"), a role.
  accent,

  /// Something good that has already happened: "You're in", "Verified",
  /// "Accepted".
  success,

  /// Something in flight that needs patience, not action: "Request
  /// pending", "Coming soon".
  warning,

  /// Something that went wrong or is being undone: "Cancelled".
  danger,

  /// Information with no valence at all: "Withdrawn", "You", a count.
  neutral,
}

/// The resolved colours for a tone: what to paint behind it, and what to
/// paint on it.
///
/// Foreground is [AppPalette.verifiedText] / [AppPalette.dangerOnTint]
/// rather than the raw `verified` / `danger`, because a tag is BY
/// DEFINITION small coloured text on a tinted ground — the exact case
/// those two tokens exist for. Using the fill colour as the label colour
/// is the single easiest way to ship text that fails AA.
({Color fill, Color fg}) resolveTone(AppTone tone) {
  switch (tone) {
    case AppTone.accent:
      return (fill: AppPalette.accentTint, fg: AppPalette.candyBlue);
    case AppTone.success:
      return (
        fill: AppPalette.verified.withValues(
          alpha: AppPalette.isLight ? 0.11 : 0.14,
        ),
        fg: AppPalette.verifiedText,
      );
    case AppTone.warning:
      return (
        fill: AppPalette.gold.withValues(
          alpha: AppPalette.isLight ? 0.13 : 0.14,
        ),
        fg: AppPalette.gold,
      );
    case AppTone.danger:
      return (
        fill: AppPalette.danger.withValues(alpha: 0.14),
        fg: AppPalette.dangerOnTint,
      );
    case AppTone.neutral:
      return (fill: AppPalette.raised, fg: AppPalette.textSecondary);
  }
}

/// A small status pill: "Coffee", "You're in", "Request pending", "Full".
///
/// # IT REPLACED FOUR NEARLY-IDENTICAL BADGES
///
/// `MeetupStatusBadge`, `TrustLevelBadge` and two one-off `Container`s
/// inside the card widgets all drew the same thing with slightly different
/// padding, radius, weight and tracking — and three of the four used a
/// 10%-alpha fill with the FULL-STRENGTH colour as the label, which is how
/// the app ended up with 10px text at 3-point-something contrast in
/// several places.
///
/// The fill is composited onto whatever surface the tag sits on via
/// [AppPalette.tintedSurface] rather than left translucent, so a tag on a
/// card does not let the page ground show through it.
class AppTag extends StatelessWidget {
  const AppTag(
    this.label, {
    super.key,
    this.tone = AppTone.accent,
    this.icon,
    this.compact = false,
    this.onSurface,
  });

  final String label;
  final AppTone tone;

  /// One of the `AppIcons.*` stroke paths.
  final String? icon;

  /// The denser variant used inside list rows, where several tags share a
  /// line with a title.
  final bool compact;

  /// The surface this tag is being drawn on, for compositing the tint.
  /// Defaults to [AppPalette.card]; pass [AppPalette.raised] for a tag
  /// inside an already-raised control, or the page ground for a tag that
  /// sits directly on it.
  final Color? onSurface;

  @override
  Widget build(BuildContext context) {
    final (fill: fill, fg: fg) = resolveTone(tone);
    final double size = compact ? 10 : 11;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 10,
        vertical: compact ? 2.5 : 4,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(99),
        color: Color.alphaBlend(fill, onSurface ?? AppPalette.card),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            AppIcon(icon!, size: size + 2, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: size,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
              height: 1.25,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}
