import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The intent's landing-collage scene, faint, along the right side of a
/// card — the "premium" backdrop treatment. Meant to be the first child
/// of a `Stack` behind the card's content.
///
/// # WHY IT IS DRAWN THIS WAY
///
/// Cards live in scrolling lists, so the backdrop must not cost a
/// `saveLayer` per card (which `Opacity` and `ShaderMask` both would).
/// Two cheap operations instead:
///
///  1. The image is painted with the card colour blended over it
///     (`colorBlendMode: srcATop`), which dims it to a tint in a single
///     draw call — no offscreen buffer.
///  2. A plain gradient from the card colour to transparent is painted on
///     top, so the scene fades out toward the text side and the text sits
///     on solid card colour regardless of what the picture shows.
///
/// Decoded at the panel's own pixel width; there are only as many distinct
/// images as intents, so the image cache holds at most that many.
class IntentBackdrop extends StatelessWidget {
  const IntentBackdrop({
    super.key,
    required this.intent,
    this.widthFactor = 0.55,
  });

  final IntentType intent;

  /// Fraction of the card's width the scene occupies, from the right.
  final double widthFactor;

  @override
  Widget build(BuildContext context) {
    final card = AppPalette.card;
    // Lighter tint on the light theme, where a picture competes harder
    // with dark text; deeper on dark, where it would otherwise vanish.
    final veil = AppPalette.isLight ? 0.88 : 0.86;
    return Positioned.fill(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final dpr = MediaQuery.devicePixelRatioOf(context);
            final panel = constraints.maxWidth * widthFactor;
            return Stack(
              children: [
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: panel,
                  child: Image.asset(
                    intent.imageAsset,
                    fit: BoxFit.cover,
                    alignment: Alignment.center,
                    color: card.withValues(alpha: veil),
                    colorBlendMode: BlendMode.srcATop,
                    cacheWidth: (panel * dpr).round(),
                    excludeFromSemantics: true,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: panel,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [card, card.withValues(alpha: 0.0)],
                        stops: const [0.0, 0.75],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
