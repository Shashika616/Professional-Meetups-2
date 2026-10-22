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
    this.radius = 22,
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

  /// Dark mode's edge light — the screen set's
  /// `inset 0 1px 0 rgba(255,255,255,.05)`, which Flutter has no inset
  /// shadow for.
  ///
  /// A card is lifted the way a lit surface is: a touch brighter along its
  /// top edge than at its bottom. This is what replaced the 1px outline
  /// every dark card used to draw (see [AppPalette.hairline] for why that
  /// went). The highlight is concentrated in the top few percent rather
  /// than spread over the whole card, so it reads as an edge catching
  /// light instead of as a gradient fill.
  ///
  /// Light mode keeps a flat fill and lets the shadow do the work.
  Gradient? get _lift {
    if (AppPalette.isLight) return null;
    final surface = _surface;
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      stops: const [0.0, 0.06, 1.0],
      colors: [
        Color.alphaBlend(Colors.white.withValues(alpha: 0.055), surface),
        surface,
        surface,
      ],
    );
  }

  List<BoxShadow>? get _shadow {
    // Dark mode DOES get a shadow now (the screen set's
    // `0 8px 24px rgba(0,0,0,.28)`). The old comment here said a drop
    // shadow "against a near-black background is invisible", which was
    // true of the near-black ground this used to sit on. The redesign's
    // ground is #070D15 and the card on it is #0F1824 — the card is
    // LIGHTER than the page, so a soft dark cast underneath reads
    // perfectly well and is what stops a column of cards looking pasted
    // on. It stays soft and offset downward; no halo.
    if (!AppPalette.isLight) {
      return [
        BoxShadow(
          color: Colors.black.withValues(alpha: elevated ? 0.38 : 0.28),
          blurRadius: elevated ? 30 : 24,
          offset: Offset(0, elevated ? 12 : 8),
        ),
      ];
    }
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
    // The ordinary card, light mode: a tight contact shadow and a soft,
    // wider cast, so it sits ON the page rather than being drawn on it.
    // Lighter than the elevated pair above, so the one card meant to be
    // read first still stands out.
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.04),
        blurRadius: 2,
        offset: const Offset(0, 1),
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.07),
        blurRadius: 14,
        offset: const Offset(0, 5),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Container(
        padding: padding,
        // Children are clipped to the card's corners: an accent bar down
        // one edge, a picture, anything drawn to the edge stays inside
        // the rounded outline instead of poking past the border.
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: _lift == null ? _surface : null,
          gradient: _lift,
          // No outline unless a call site explicitly asks for one. Dark
          // cards separate by fill + the top edge light above; light cards
          // separate by fill + shadow. The hairline-on-everything look was
          // the single biggest reason a list of cards read as a stack of
          // grey rectangles. Call sites that pass `border:` (a cancelled
          // meetup's red edge, a selected tile) still get exactly that.
          border: border == null ? null : Border.all(color: border!, width: 1),
          boxShadow: _shadow,
        ),
        child: child,
      ),
    );
  }
}
