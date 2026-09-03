import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The Professional Connections app icon: the brand watch dial artwork.
/// Renders as a rounded square (like a real app icon) at any size,
/// with an optional candy blue glow for hero placements.
class AppIcon extends StatelessWidget {
  const AppIcon({super.key, this.size = 48, this.radius, this.glow = false});

  final double size;
  final double? radius;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final double cornerRadius = radius ?? size * 0.24;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
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
      child: ClipRRect(
        borderRadius: BorderRadius.circular(cornerRadius),
        child: Image.asset(
          'assets/images/watch/app_icon.png',
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => Container(
            color: AppPalette.deepBlue,
            child: Icon(
              Icons.person,
              size: size * 0.5,
              color: AppPalette.candyBlue,
            ),
          ),
        ),
      ),
    );
  }
}
