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
/// `tint`/`border` overrides (several call sites pass a low-alpha color
/// tint for a semantic card — danger/verified/selected-state accents) keep
/// working exactly as before: a translucent color painted flat over
/// `AppPalette.card` reads as a normal tinted flat card, which is what
/// several of those call sites were already going for.
class FlatCard extends StatelessWidget {
  const FlatCard({
    super.key,
    required this.child,
    this.radius = 20,
    this.padding,
    this.tint,
    this.border,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final Color? tint;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: tint ?? AppPalette.card,
          border: Border.all(color: border ?? AppPalette.glassBorder, width: 1),
          // Light mode only — a solid near-white card has nothing but the
          // hairline border to separate it from AppBackground's equally
          // light fade without a touch of real elevation; dark mode skips
          // this entirely, since a drop shadow doesn't read against a
          // near-black background and the hairline border alone already
          // carries the separation there (ADR-032 Step 1).
          boxShadow: AppPalette.isLight
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 6,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: child,
      ),
    );
  }
}
