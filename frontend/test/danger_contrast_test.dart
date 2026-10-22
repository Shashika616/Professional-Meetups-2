import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// UI review #23: the SOS control is the one someone uses when they feel
/// unsafe, and its label was below the WCAG AA contrast minimum in both
/// themes. These tests recompute the ratio from the palette rather than
/// trusting a number written down once, so a later palette change that
/// breaks it fails here instead of shipping.
///
/// 4.5:1 is the AA minimum for text under 18.66px bold. The SOS label is
/// 13px, so the 3:1 large-text allowance does not apply to it.
void main() {
  /// WCAG relative luminance.
  double luminance(Color c) {
    double channel(double v) => v <= 0.03928
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(c.r) +
        0.7152 * channel(c.g) +
        0.0722 * channel(c.b);
  }

  double contrast(Color a, Color b) {
    final la = luminance(a);
    final lb = luminance(b);
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// The composited colour of `fg` at `alpha` over `bg` — what a tinted
  /// FlatCard actually paints, and therefore what the text sits on.
  Color over(Color fg, Color bg, double alpha) {
    return Color.fromARGB(
      255,
      ((fg.r * alpha + bg.r * (1 - alpha)) * 255).round(),
      ((fg.g * alpha + bg.g * (1 - alpha)) * 255).round(),
      ((fg.b * alpha + bg.b * (1 - alpha)) * 255).round(),
    );
  }

  /// The SOS card's tint, as safety_page.dart sets it.
  const sosTintAlpha = 0.12;
  const minimumAA = 4.5;

  for (final light in [true, false]) {
    final theme = light ? 'light' : 'dark';

    test('the SOS label clears WCAG AA on its own card ($theme)', () {
      AppPalette.setMode(light ? AppThemeMode.light : AppThemeMode.dark);
      final cardBackground = over(
        AppPalette.danger,
        AppPalette.card,
        sosTintAlpha,
      );
      final ratio = contrast(AppPalette.dangerOnTint, cardBackground);

      expect(
        ratio,
        greaterThanOrEqualTo(minimumAA),
        reason:
            'TRIGGER SOS is ${ratio.toStringAsFixed(2)}:1 on its card in '
            '$theme mode, below the $minimumAA:1 AA minimum for 13px text',
      );
    });

    test('and it is still recognisably the danger red, not a substitute '
        '($theme)', () {
      AppPalette.setMode(light ? AppThemeMode.light : AppThemeMode.dark);
      // Within a small distance of `danger`: the fix was a nudge for
      // legibility, not a different colour. If someone "fixes" the ratio by
      // reaching for white or grey, this fails and says why.
      final d = AppPalette.danger;
      final t = AppPalette.dangerOnTint;
      final distance =
          ((d.r - t.r).abs() + (d.g - t.g).abs() + (d.b - t.b).abs()) / 3;
      expect(
        distance,
        lessThan(0.15),
        reason:
            'dangerOnTint has drifted away from danger; it should be the '
            'same red, only legible',
      );
    });
  }

  tearDown(() => AppPalette.setMode(AppThemeMode.dark));
}
