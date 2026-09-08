import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The shared flat-card surface (ADR-032 — replaces the old `Glass`
/// blurred-glass widget; renamed, not just restyled, since a `Glass` name
/// that draws no glass would confuse the next reader). No backdrop blur
/// filter — a plain solid `Container` with a hairline border and, in light
/// mode only, a faint real elevation shadow. Same constructor shape as
/// `Glass` (`child`/`radius`/`padding`/`tint`/`border`) so every call site
/// only needed a rename; `blur` is dropped entirely (it's meaningless
/// without a backdrop filter) — its one real caller (`AppBottomBar`) was
/// updated to stop passing it.
///
/// # THE TINT IS COMPOSITED, NOT SUBSTITUTED
///
/// `tint` is a semantic accent (danger / verified / selected), and every one
/// of its nine call sites passes a 6–15% alpha colour. This used to assign
/// that straight to `color`, which does not tint a card — it makes the card
/// 85–94% TRANSPARENT, so `AppBackground`'s photo showed through all of
/// them. That was the murky "glass" look, and it was worst in light mode,
/// where a dark desaturated photo sits behind a near-white surface.
///
/// The comment here used to claim the tint was "painted flat over
/// AppPalette.card". That is what it does now, via
/// [AppPalette.tintedSurface] — the call sites keep their exact colours and
/// alphas, and get the accent they were always asking for.
class FlatCard extends StatelessWidget {
  const FlatCard({
    super.key,
    required this.child,
    this.radius = 20,
    this.padding,
    this.tint,
    this.border,
    this.elevated = false,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final Color? tint;
  final Color? border;

  /// Lifts this card off the page, for the one card on a screen that is meant
  /// to be read first.
  ///
  /// # IT IS NOT "A BIGGER SHADOW" IN BOTH THEMES
  ///
  /// A drop shadow conveys elevation against a light ground and does almost
  /// nothing against a near-black one — which is why the ordinary card below
  /// skips shadows entirely in dark mode. So elevation here is expressed the
  /// way each theme actually reads it: a real shadow on light, and a
  /// LIGHTER SURFACE on dark, which is how material surfaces signal height
  /// against a dark background.
  ///
  /// Use sparingly. If everything is elevated, nothing is.
  final bool elevated;

  /// The card's fill. An [elevated] card on the DARK theme is lifted by
  /// making the surface lighter rather than by a shadow that would not read.
  Color get _surface {
    final base = tint == null
        ? AppPalette.card
        : AppPalette.tintedSurface(tint!);
    if (!elevated || AppPalette.isLight) return base;
    return Color.alphaBlend(
      AppPalette.textPrimary.withValues(alpha: 0.05),
      base,
    );
  }

  List<BoxShadow>? get _shadow {
    // Dark mode: no shadow at any elevation. A drop shadow against a
    // near-black background is invisible, and faking it with a darker halo
    // reads as a smudge — the lighter surface above does the work instead.
    if (!AppPalette.isLight) return null;
    if (elevated) {
      // Two layers: a tight one for the contact edge and a wide, soft one
      // for the cast. One blurred shadow alone reads as a grey glow rather
      // than a lift.
      return [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.05),
          blurRadius: 2,
          offset: const Offset(0, 1),
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.09),
          blurRadius: 18,
          offset: const Offset(0, 8),
        ),
      ];
    }
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.06),
        blurRadius: 6,
        offset: const Offset(0, 1),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: _surface,
          border: Border.all(color: border ?? AppPalette.hairline, width: 1),
          // Light mode only — a solid near-white card has nothing but the
          // hairline border to separate it from AppBackground's equally
          // light fade without a touch of real elevation; dark mode skips
          // this entirely, since a drop shadow doesn't read against a
          // near-black background and the hairline border alone already
          // carries the separation there (ADR-032 Step 1).
          boxShadow: _shadow,
        ),
        child: child,
      ),
    );
  }
}
