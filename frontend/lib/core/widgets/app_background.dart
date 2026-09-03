import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

class AppBackground extends StatelessWidget {
  const AppBackground({
    super.key,
    required this.child,
    this.imageOpacity = 0.28,
  });

  final Widget child;
  final double imageOpacity;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Container(
        color: AppPalette.onyx,
        child: Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: ColorFiltered(
                  colorFilter: const ColorFilter.mode(
                    Color(0xFF808080),
                    BlendMode.saturation,
                  ),
                  child: Opacity(
                    opacity: imageOpacity,
                    child: Image.asset(
                      'assets/images/suit.png',
                      fit: BoxFit.cover,
                      cacheWidth: 1080, // Limit cache size
                      errorBuilder: (context, error, stackTrace) =>
                          const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.0, 0.5, 1.0],
                    colors: [
                      AppPalette.onyx.withValues(alpha: 0.50),
                      AppPalette.onyx.withValues(alpha: 0.82),
                      AppPalette.onyx,
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(child: child),
          ],
        ),
      ),
    );
  }
}
