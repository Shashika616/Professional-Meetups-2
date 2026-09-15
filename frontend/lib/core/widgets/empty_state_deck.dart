import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';

/// An empty screen that still looks like part of the app: three of the
/// landing collage's scenes fanned out like a hand of cards, a friendly
/// line about what will appear here, and (when there is one) the action
/// that fills it. The scenes are already in the bundle, so an empty page
/// costs nothing new and shares the app's own artwork rather than a stock
/// illustration. One widget for every empty list, so they all read the
/// same.
///
/// Each caller picks the three scenes that suit it ([EmptyDeckScenes] has
/// the ones in use); the fan itself never changes, which is what makes the
/// pages feel like one app.
class EmptyStateDeck extends StatelessWidget {
  const EmptyStateDeck({
    super.key,
    required this.title,
    required this.message,
    this.scenes = EmptyDeckScenes.meetups,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  });

  final String title;
  final String message;

  /// Exactly three asset paths, drawn left to right; the middle one sits
  /// on top.
  final List<String> scenes;

  /// An optional single action under the copy.
  final String? actionLabel;
  final VoidCallback? onAction;

  /// A smaller fan and tighter spacing, for an empty state inside a
  /// section rather than a whole page.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    assert(scenes.length == 3, 'the deck fans exactly three scenes');
    final fanHeight = compact ? 128.0 : 172.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, compact ? 12 : 36, 24, compact ? 8 : 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CardFan(scenes: scenes, height: fanHeight),
          SizedBox(height: compact ? 16 : 24),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: compact ? 15 : 17,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            SizedBox(height: compact ? 16 : 22),
            SizedBox(
              width: 220,
              child: PrimaryButton(
                label: actionLabel!,
                height: 44,
                onPressed: onAction,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Three rounded photo cards spread from one point at the bottom, the way
/// cards are held in a hand: the outer two lean out and sit a little
/// lower, the middle one is upright and on top.
class _CardFan extends StatelessWidget {
  const _CardFan({required this.scenes, required this.height});

  final List<String> scenes;
  final double height;

  @override
  Widget build(BuildContext context) {
    final cardHeight = height;
    final cardWidth = height * 0.72;
    const spread = 14.0; // degrees each outer card leans
    final shift = cardWidth * 0.62; // how far the outer cards sit apart
    return SizedBox(
      height: height + 12,
      width: cardWidth + 2 * shift + 24,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          _card(scenes[0], -spread, -shift, cardWidth, cardHeight, 0.9),
          _card(scenes[2], spread, shift, cardWidth, cardHeight, 0.9),
          _card(scenes[1], 0, 0, cardWidth, cardHeight, 1),
        ],
      ),
    );
  }

  Widget _card(
    String asset,
    double degrees,
    double dx,
    double width,
    double height,
    double scale,
  ) {
    return Positioned(
      bottom: degrees == 0 ? 12 : 0,
      child: Transform.translate(
        offset: Offset(dx, 0),
        child: Transform.rotate(
          angle: degrees * math.pi / 180,
          // Rotate about the bottom edge, where the hand holds the cards.
          alignment: Alignment.bottomCenter,
          child: Transform.scale(
            scale: scale,
            child: Container(
              width: width,
              height: height,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppPalette.hairline),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: AppPalette.isLight ? 0.14 : 0.45,
                    ),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.asset(asset, fit: BoxFit.cover),
            ),
          ),
        ),
      ),
    );
  }
}

/// The scene trios in use, named by the page they stand in for. All from
/// the landing collage, chosen by eye for the subject: coffee cups and
/// tables for meetups, a mixer and a whiteboard for the requests a host
/// reviews, a quiet room for an empty inbox.
abstract final class EmptyDeckScenes {
  static const meetups = [
    'assets/images/landing/l11.jpg',
    'assets/images/landing/l13.jpg',
    'assets/images/landing/l14.jpg',
  ];
  static const requests = [
    'assets/images/landing/l10.jpg',
    'assets/images/landing/l14.jpg',
    'assets/images/landing/l05.jpg',
  ];
  static const inbox = [
    'assets/images/landing/l02.jpg',
    'assets/images/landing/l13.jpg',
    'assets/images/landing/l07.jpg',
  ];
}
