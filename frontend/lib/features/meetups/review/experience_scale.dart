import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The five points of "How was your experience?", each with its own face,
/// colour and word.
///
/// # WHY A FACE AND NOT FIVE STARS
///
/// The overall question and the per-person question are different questions,
/// and showing both as stars makes them look like the same one asked twice.
/// A face answers "how did that feel" in a way a number does not, and it is
/// the one moment in this flow that is allowed to be expressive — the
/// per-person step immediately after is deliberately plainer.
enum ExperienceLevel {
  veryBad(1, 'Very bad'),
  bad(2, 'Bad'),
  okay(3, 'Okay'),
  good(4, 'Very good'),
  excellent(5, 'Excellent');

  const ExperienceLevel(this.score, this.label);

  final int score;
  final String label;

  static ExperienceLevel fromScore(int score) =>
      values.firstWhere((v) => v.score == score, orElse: () => okay);

  /// Hue per level, red through green. Deliberately not the palette's own
  /// semantic colours: this is a five-step ramp and `danger`/`verified` are
  /// only two points on it, so the middle would have nothing to use.
  Color get color => switch (this) {
    ExperienceLevel.veryBad => const Color(0xFFE05252),
    ExperienceLevel.bad => const Color(0xFFE08A4B),
    ExperienceLevel.okay => const Color(0xFFD8A73C),
    ExperienceLevel.good => const Color(0xFF56B98A),
    ExperienceLevel.excellent => const Color(0xFF3FA372),
  };

  /// How far the mouth curves: -1 is a full frown, +1 a full smile.
  double get mouthCurve => switch (this) {
    ExperienceLevel.veryBad => -1.0,
    ExperienceLevel.bad => -0.5,
    ExperienceLevel.okay => 0.0,
    ExperienceLevel.good => 0.6,
    ExperienceLevel.excellent => 1.0,
  };

  /// How wide the eyes open. The happiest face's eyes are largest, the
  /// unhappiest are narrowed — the detail that stops the three middle faces
  /// reading as the same drawing with a different mouth.
  double get eyeOpenness => switch (this) {
    ExperienceLevel.veryBad => 1.0,
    ExperienceLevel.bad => 0.45,
    ExperienceLevel.okay => 0.7,
    ExperienceLevel.good => 0.85,
    ExperienceLevel.excellent => 1.0,
  };
}

/// A face drawn from two eyes and one curve, animated between levels.
///
/// Drawn rather than shipped as five images or emoji: the whole point is
/// that the mouth MOVES as the slider moves, which no static asset can do,
/// and a system emoji would render differently on every platform in a screen
/// where it is the largest thing on it.
///
/// # WHY ONE ANIMATED VALUE DRIVES THREE PROPERTIES
///
/// Mouth curve, eye openness and colour are all functions of the same
/// thing — where you are on the 1-5 ramp — so this animates the POSITION and
/// derives the rest. Animating each separately would mean nested builders
/// rebuilding the same painter two or three times per frame, and would let
/// the three drift out of step mid-transition, which reads as a face
/// changing its mouth before its mind.
class ExperienceFace extends StatelessWidget {
  const ExperienceFace({super.key, required this.level, this.size = 150});

  /// Null before anything is picked — a neutral, greyed face.
  final ExperienceLevel? level;
  final double size;

  @override
  Widget build(BuildContext context) {
    final target = level;
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      // Position on the ramp, 0-4. Neutral sits at the middle stop.
      tween: Tween(
        end: (target?.index ?? ExperienceLevel.okay.index).toDouble(),
      ),
      builder: (context, position, _) {
        return SizedBox(
          width: size,
          height: size * 0.72,
          child: CustomPaint(
            painter: _FacePainter(
              curve: _lerpAlongRamp(position, (l) => l.mouthCurve),
              eyeOpenness: _lerpAlongRamp(position, (l) => l.eyeOpenness),
              // Grey until a choice is made: a coloured face before anyone
              // has answered would look like an answer.
              color: target == null
                  ? AppPalette.textSecondary
                  : _lerpColorAlongRamp(position),
            ),
          ),
        );
      },
    );
  }
}

/// Interpolates a per-level scalar at a fractional position on the ramp, so
/// a transition passes THROUGH the intermediate faces rather than jumping
/// between two endpoints.
double _lerpAlongRamp(
  double position,
  double Function(ExperienceLevel) select,
) {
  final levels = ExperienceLevel.values;
  final clamped = position.clamp(0.0, (levels.length - 1).toDouble());
  final lower = clamped.floor();
  final upper = clamped.ceil();
  if (lower == upper) return select(levels[lower]);
  return select(levels[lower]) +
      (select(levels[upper]) - select(levels[lower])) * (clamped - lower);
}

Color _lerpColorAlongRamp(double position) {
  final levels = ExperienceLevel.values;
  final clamped = position.clamp(0.0, (levels.length - 1).toDouble());
  final lower = clamped.floor();
  final upper = clamped.ceil();
  if (lower == upper) return levels[lower].color;
  return Color.lerp(levels[lower].color, levels[upper].color, clamped - lower)!;
}

class _FacePainter extends CustomPainter {
  _FacePainter({
    required this.curve,
    required this.eyeOpenness,
    required this.color,
  });

  final double curve;
  final double eyeOpenness;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final eyeW = size.width * 0.19;
    final eyeH = eyeW * eyeOpenness.clamp(0.28, 1.0);
    final eyeY = size.height * 0.30;
    for (final dx in [size.width * 0.30, size.width * 0.70]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(dx, eyeY), width: eyeW, height: eyeH),
          Radius.circular(eyeW / 2),
        ),
        paint,
      );
    }

    // One quadratic curve whose control point rises and falls with [curve],
    // so a frown, a flat line and a smile are all the same stroke.
    final mouthWidth = size.width * 0.44;
    final mouthY = size.height * 0.74;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.075
      ..strokeCap = StrokeCap.round;

    final left = Offset((size.width - mouthWidth) / 2, mouthY);
    final right = Offset((size.width + mouthWidth) / 2, mouthY);
    final control = Offset(
      size.width / 2,
      mouthY + curve.clamp(-1.0, 1.0) * size.height * 0.30,
    );
    canvas.drawPath(
      Path()
        ..moveTo(left.dx, left.dy)
        ..quadraticBezierTo(control.dx, control.dy, right.dx, right.dy),
      stroke,
    );
  }

  @override
  bool shouldRepaint(_FacePainter old) =>
      old.curve != curve ||
      old.eyeOpenness != eyeOpenness ||
      old.color != color;
}

/// The five-stop slider under the face.
///
/// A real [Slider] would be continuous and would need snapping bolted on;
/// this is five taps and a drag across five stops, which is what the control
/// actually is.
class ExperienceSlider extends StatelessWidget {
  const ExperienceSlider({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final ExperienceLevel? value;
  final ValueChanged<ExperienceLevel> onChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final levels = ExperienceLevel.values;
        final step = width / levels.length;

        void selectAt(double dx) {
          final index = (dx / step).floor().clamp(0, levels.length - 1);
          if (levels[index] != value) onChanged(levels[index]);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => selectAt(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => selectAt(d.localPosition.dx),
          child: SizedBox(
            height: 56,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: AppPalette.hairline,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    for (final level in levels)
                      _Stop(selected: value == level, color: level.color),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Stop extends StatelessWidget {
  const _Stop({required this.selected, required this.color});

  final bool selected;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // The springiness lives on the SCALE, not on the AnimatedContainer.
    //
    // An overshooting curve (easeOutBack) on a widget that lerps a
    // BoxShadow drives the interpolation below zero, and BoxShadow.lerp
    // asserts on a negative blur radius — a real crash on deselect, not
    // just a test failure. Transforms tolerate overshoot; decorations do
    // not. So the container eases, and the bounce is a scale on top.
    return AnimatedScale(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutBack,
      scale: selected ? 1 : 0.92,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        width: selected ? 34 : 12,
        height: selected ? 34 : 12,
        decoration: BoxDecoration(
          color: selected
              ? color
              : AppPalette.textSecondary.withValues(alpha: 0.5),
          shape: BoxShape.circle,
          boxShadow: [
            // Always present, faded to nothing when unselected — lerping
            // between two shadows keeps every intermediate blur radius
            // positive, where lerping to null does not.
            BoxShadow(
              color: color.withValues(alpha: selected ? 0.45 : 0),
              blurRadius: 14,
              spreadRadius: 1,
            ),
          ],
        ),
        child: selected
            ? const Icon(Icons.check_rounded, size: 18, color: Colors.white)
            : null,
      ),
    );
  }
}
