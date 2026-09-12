import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The sign in illustration: two people at a cafe table with a laptop and a
/// coffee.
///
/// # WHY AN IMAGE AND NOT A PAINTER
///
/// This started as a CustomPainter drawing the scene from primitives. It was
/// replaced because line and flat shape work cannot carry a human figure at
/// this size: the painted version went through three passes and never got
/// past reading as a mannequin. A real illustration does in one asset what
/// several hundred lines of path geometry could not.
///
/// # HOW IT ADAPTS TO THE THEME
///
/// The artwork has its background cut away entirely, blob and wall included,
/// so it sits directly on whatever ground the page paints instead of carrying
/// a pale slab of its own.
///
/// Light mode draws it untouched.
///
/// Dark mode does NOT invert it. Inversion suits line art and ruins figures:
/// it turns skin dark and hair white, and the result reads as a photographic
/// negative. It does not dim it either, which was the first attempt and made
/// things worse once the background came off, because the darkest parts of
/// the drawing (hair, trousers, the chairs) then merged into a near black
/// page and the figures lost their outlines.
///
/// What it does is LIFT THE BLACK POINT: every tone is compressed into
/// [_darkFloor]..255, so nothing in the artwork is darker than the page it
/// sits on. Tonal order is preserved, so the drawing still reads correctly,
/// and the parts that used to disappear now separate.
class CafeScene extends StatelessWidget {
  const CafeScene({super.key, this.height = 168});

  final double height;

  /// The floor tone dark mode lifts everything above, chosen by looking at
  /// it against the real page. At 0 (no lift) the black clothing vanishes
  /// into the background; by about 90 the whole illustration has gone flat
  /// and grey. 55 keeps every element separated without losing contrast.
  static const double _darkFloor = 55;
  static const double _scale = (255 - _darkFloor) / 255;

  static const ColorFilter _liftForDark = ColorFilter.matrix(<double>[
    _scale, 0, 0, 0, _darkFloor, //
    0, _scale, 0, 0, _darkFloor, //
    0, 0, _scale, 0, _darkFloor, //
    0, 0, 0, 1, 0, //
  ]);

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      'assets/images/brand/cafe_scene.png',
      height: height,
      fit: BoxFit.contain,
      // Decodes at the size actually drawn rather than at the asset's full
      // resolution. Without it this holds a 904px bitmap in memory to paint
      // something around 170px tall.
      cacheHeight: (height * MediaQuery.devicePixelRatioOf(context)).round(),
      // Purely decorative. It repeats what the heading above it already says,
      // so announcing it would be noise rather than information.
      excludeFromSemantics: true,
      errorBuilder: (context, error, stackTrace) => SizedBox(height: height),
    );

    if (AppPalette.isLight) return image;
    return ColorFiltered(colorFilter: _liftForDark, child: image);
  }
}
