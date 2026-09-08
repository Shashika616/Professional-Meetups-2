import 'dart:math';

import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// Intent chips slowly orbiting the brand core with a subtle depth effect.
/// Optimized for low-end devices using RepaintBoundary and pre-calculated values.
class OrbitingIntents extends StatefulWidget {
  const OrbitingIntents({super.key});

  @override
  State<OrbitingIntents> createState() => _OrbitingIntentsState();
}

class _OrbitingIntentsState extends State<OrbitingIntents>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  static const List<IntentType> _intents = [
    IntentType.coffee,
    IntentType.networking,
    IntentType.mentorship,
    IntentType.rideShare,
    IntentType.lunch,
    IntentType.dating,
  ];

  // Pre-calculate angle offsets for each chip (avoids division in build)
  static final List<double> _angleOffsets = List.generate(
    _intents.length,
    (i) => i * (2 * pi / _intents.length),
  );

  // Orbit dimensions - wider for premium feel
  static const double _containerSize = 380;
  static const double _centerX = _containerSize / 2;
  static const double _centerY = _containerSize / 2;
  static const double _radiusX = 200;
  static const double _radiusY = 175;
  static const double _chipWidth = 72;
  static const double _chipHeight = 52;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 45), // Slower, more premium
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final double t = _controller.value * 2 * pi;
          return SizedBox(
            width: _containerSize,
            height: _containerSize,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                for (var i = 0; i < _intents.length; i++)
                  _buildOrbitChip(t + _angleOffsets[i], _intents[i]),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildOrbitChip(double angle, IntentType intent) {
    final double sinAngle = sin(angle);
    final double cosAngle = cos(angle);

    // depth: 0 = behind (top), 1 = in front (bottom)
    final double depth = (sinAngle + 1) / 2;
    final double x = _centerX + cosAngle * _radiusX;
    final double y = _centerY + sinAngle * _radiusY;
    final double scale = 0.75 + 0.3 * depth;
    final double opacity = 0.4 + 0.6 * depth;

    return Positioned(
      left: x - _chipWidth / 2,
      top: y - _chipHeight / 2,
      child: Transform.scale(
        scale: scale,
        transformHitTests: false, // Skip hit testing for performance
        child: Opacity(
          opacity: opacity,
          child: _ChipContent(intent: intent),
        ),
      ),
    );
  }
}

/// Extracted as a separate StatelessWidget so Flutter can cache and reuse it,
/// avoiding full rebuilds of the Container/Column tree on every frame.
class _ChipContent extends StatelessWidget {
  const _ChipContent({required this.intent});

  final IntentType intent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: AppPalette.surface.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppPalette.hairline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(intent.icon, size: 17, color: AppPalette.candyBlue),
          const SizedBox(height: 4),
          Text(
            intent.label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 7,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
              color: AppPalette.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
