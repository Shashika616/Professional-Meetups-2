import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// One placeholder block. Deliberately just a shape and a tint — the motion
/// comes from a [Shimmer] ancestor, which [SkeletonLoader] supplies, so a
/// dozen boxes share one sweep instead of a dozen out-of-phase ones.
///
/// Use it inside a [SkeletonLoader] rather than on its own: that is what
/// adds both the shimmer and the delay-before-showing.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    required this.width,
    required this.height,
    this.radius = 6,
    this.opacity = 0.06,
  });

  final double width;
  final double height;
  final double radius;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    // Was a fixed Colors.white tint — invisible once Slice G's light theme
    // puts this over a near-white card instead of the original near-black
    // one. AppPalette.textPrimary adapts automatically (near-white in dark
    // mode, near-black in light mode), and light mode also gets a boosted
    // effective alpha: the same low percentage reads much fainter against a
    // bright background than against a dark one, so matching the dark-mode
    // alpha exactly left the light-mode placeholder essentially invisible.
    final effectiveOpacity = AppPalette.isLight
        ? (opacity * 2.2).clamp(0.0, 1.0)
        : opacity;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppPalette.textPrimary.withValues(alpha: effectiveOpacity),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}
