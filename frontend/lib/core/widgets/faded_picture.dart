import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// An illustration whose edges dissolve into whatever sits behind it, so a
/// picture reads as part of the card instead of a rectangle pasted onto it.
/// Used for the failure and empty states.
///
/// A missing or unreadable asset draws nothing rather than the framework's
/// red error box: the picture is decoration, and the copy beside it has to
/// stand on its own.
class FadedPicture extends StatelessWidget {
  const FadedPicture({
    super.key,
    required this.asset,
    required this.height,
    this.aspectRatio = 1.75,
  });

  final String asset;
  final double height;
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (rect) => RadialGradient(
        center: Alignment.center,
        radius: 0.78,
        colors: const [Colors.white, Colors.white, Colors.transparent],
        stops: const [0, 0.55, 1],
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: SizedBox(
        height: height,
        width: height * aspectRatio,
        child: Opacity(
          opacity: AppPalette.isLight ? 0.92 : 0.85,
          child: Image.asset(
            asset,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
