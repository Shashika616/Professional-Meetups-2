import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/app_tag.dart';

/// The 34px rounded-square that sits at the head of a settings row, a
/// verification row or a notification: a tinted tile with one icon in it.
///
/// It exists so those rows stop starting with a bare floating glyph. A
/// 17px icon alone on a card has nothing to anchor it, and a column of
/// them reads as ragged; giving each one a fixed-size tile makes the
/// labels beside them line up by construction.
class SquareIconTile extends StatelessWidget {
  const SquareIconTile(
    this.icon, {
    super.key,
    this.tone = AppTone.accent,
    this.size = 34,
    this.onSurface,
  });

  /// One of the `AppIcons.*` stroke paths.
  final String icon;
  final AppTone tone;
  final double size;

  /// The surface the tile is drawn on, for compositing the tint. See
  /// [AppTag.onSurface].
  final Color? onSurface;

  @override
  Widget build(BuildContext context) {
    final (fill: fill, fg: fg) = resolveTone(tone);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // The accent tone uses the neutral raised surface rather than a
        // blue tint: it is the DEFAULT tone, so tinting it would leave
        // every row on a settings page glowing blue and nothing standing
        // out. Tints are reserved for the tones that mean something.
        color: tone == AppTone.accent
            ? AppPalette.raised
            : Color.alphaBlend(fill, onSurface ?? AppPalette.card),
        borderRadius: BorderRadius.circular(12),
      ),
      child: AppIcon(icon, size: size * 0.52, color: fg),
    );
  }
}
