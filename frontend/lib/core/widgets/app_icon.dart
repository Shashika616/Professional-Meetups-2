import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The TieHere mark, rendered as an app-icon tile at any size.
///
/// # THE TILE IS PAINTED, NOT BAKED
///
/// The artwork is the mark on transparency; this widget supplies the ground
/// beneath it from the palette. That is the whole reason it looks right in
/// both themes: a baked white tile is correct on the launcher, where it sits
/// on the user's wallpaper, and wrong inside a dark app, where a white square
/// is just a hole punched in the page.
///
/// One asset rather than a light/dark pair, so the two can never drift and a
/// future theme gets the right ground for free.
///
/// The mark itself was cut from the brand sheet by un-compositing it from its
/// white background rather than threshold-keying it - a threshold leaves the
/// JPEG's edge ringing behind as a pale halo, which is invisible on white and
/// glaringly obvious on near-black.
class BrandMarkTile extends StatelessWidget {
  const BrandMarkTile({
    super.key,
    this.size = 48,
    this.radius,
    this.glow = false,
  });

  final double size;
  final double? radius;
  final bool glow;

  /// White in light mode, matching the launcher icon and the brand sheet.
  /// In dark mode the card colour, so the tile reads as one of the app's own
  /// surfaces sitting on the page rather than as a foreign white block.
  Color get _tileColor => AppPalette.isLight ? Colors.white : AppPalette.card;

  @override
  Widget build(BuildContext context) {
    final double cornerRadius = radius ?? size * 0.24;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _tileColor,
        borderRadius: BorderRadius.circular(cornerRadius),
        border: Border.all(color: AppPalette.hairline, width: 1),
        boxShadow: glow
            ? [
                BoxShadow(
                  color: AppPalette.brandGreen.withValues(alpha: 0.22),
                  blurRadius: size * 0.35,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      // The current mark, green with white on a dark tile and green with
      // onyx on a light one — the same pair as the launcher icons. Drawn
      // from the brand SVGs rather than a bitmap: sharp at every size from
      // 48 to 170, and nothing to decode on the splash. The artwork already
      // sits inside its own margin, so it fills the tile.
      child: SvgPicture.asset(
        AppPalette.isLight
            ? 'assets/images/brand/tiehere_mark_on_light.svg'
            : 'assets/images/brand/tiehere_mark_on_dark.svg',
        width: size,
        height: size,
        fit: BoxFit.contain,
      ),
    );
  }
}
