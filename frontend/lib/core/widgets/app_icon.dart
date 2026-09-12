import 'package:flutter/material.dart';

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
class AppIcon extends StatelessWidget {
  const AppIcon({super.key, this.size = 48, this.radius, this.glow = false});

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
        border: Border.all(
          color: AppPalette.candyBlue.withValues(alpha: 0.35),
          width: 1,
        ),
        boxShadow: glow
            ? [
                BoxShadow(
                  color: AppPalette.candyBlue.withValues(alpha: 0.35),
                  blurRadius: size * 0.35,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      // The mark is inset rather than filling the tile: an app icon's artwork
      // sits inside its plate, and BoxFit.cover on a non-square mark would
      // crop the figures' heads.
      child: Padding(
        padding: EdgeInsets.all(size * 0.17),
        child: Image.asset(
          'assets/images/brand/tiehere_mark.png',
          fit: BoxFit.contain,
          // The mark is a 276px source drawn at anything from 48 to 170
          // logical pixels. Without this it decodes at full size in every
          // place it appears, including the splash, for no visible gain.
          cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
          errorBuilder: (context, error, stackTrace) => Icon(
            Icons.people_alt_rounded,
            size: size * 0.42,
            color: AppPalette.brandBlue,
          ),
        ),
      ),
    );
  }
}
