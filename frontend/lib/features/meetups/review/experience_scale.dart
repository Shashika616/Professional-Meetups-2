import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  /// The illustration for this level — the same character at the same
  /// table, so sliding between levels reads as her mood changing rather
  /// than as six unrelated pictures. [ExperienceFace.neutralAsset] is the
  /// sixth, shown before anything is picked.
  String get imageAsset => switch (this) {
    ExperienceLevel.veryBad => 'assets/images/review/very_bad.jpg',
    ExperienceLevel.bad => 'assets/images/review/bad.jpg',
    ExperienceLevel.okay => 'assets/images/review/okay.jpg',
    ExperienceLevel.good => 'assets/images/review/good.jpg',
    ExperienceLevel.excellent => 'assets/images/review/excellent.jpg',
  };

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
}

/// The illustration for the current level, cross-faded as the slider
/// moves. Replaces a line-drawn face: one character across six scenes
/// carries the mood far better than two dots and a curve, and a 280ms
/// fade between them keeps the "one thing changing its mind" feel the
/// drawn version had.
///
/// All six decode at the widget's own pixel size (cacheWidth), and
/// `gaplessPlayback` holds the outgoing picture until the incoming one
/// has decoded, so a fast drag never flashes an empty frame.
class ExperienceFace extends StatelessWidget {
  const ExperienceFace({super.key, required this.level, this.size = 150});

  /// Null before anything is picked — the neutral scene.
  final ExperienceLevel? level;

  /// Width of the picture; height follows the 16:9 landscape crop.
  final double size;

  static const neutralAsset = 'assets/images/review/neutral.jpg';

  @override
  Widget build(BuildContext context) {
    final asset = level?.imageAsset ?? neutralAsset;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final width = size;
    final height = size * 9 / 16;
    return Semantics(
      image: true,
      label: level?.label ?? 'No rating picked yet',
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              layoutBuilder: (current, previous) => Stack(
                fit: StackFit.expand,
                children: [...previous, ?current],
              ),
              child: Image.asset(
                asset,
                key: ValueKey(asset),
                fit: BoxFit.cover,
                cacheWidth: (width * dpr).round(),
                gaplessPlayback: true,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
            // No border, no card: the scene dissolves into the page instead
            // of sitting in a box. An elliptical vignette to the page ground
            // takes the corners with it — two straight edge fades left a
            // rectangle you could still see. A plain gradient, no saveLayer.
            const _Vignette(),
          ],
        ),
      ),
    );
  }
}

/// Elliptical fade from clear at the centre to the page background at
/// the edges, so the illustration has no visible boundary.
class _Vignette extends StatelessWidget {
  const _Vignette();

  @override
  Widget build(BuildContext context) {
    final ground = AppPalette.onyx;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 0.72,
            colors: [
              ground.withValues(alpha: 0.0),
              ground.withValues(alpha: 0.0),
              ground.withValues(alpha: 0.85),
              ground,
            ],
            stops: const [0.0, 0.50, 0.90, 1.0],
          ),
        ),
      ),
    );
  }
}

/// Five labelled stops on a track that fills to the chosen one.
///
/// The old version was five identical grey dots on a grey line — nothing
/// said which end was good, nothing said what a dot meant until you hit
/// it, and the dots were 12px targets on a 56px-tall strip. Now:
///
///  - The track FILLS from the left to the chosen stop, in the stop's own
///    colour, so the value reads as a level rather than a point.
///  - Each stop carries its word underneath, in the level's colour once
///    it is at or below the chosen one, so the scale explains itself.
///  - The whole column above each word is the tap target, not the dot.
///  - Selection snaps with light haptics.
class ExperienceSlider extends StatelessWidget {
  const ExperienceSlider({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final ExperienceLevel? value;
  final ValueChanged<ExperienceLevel> onChanged;

  static const _trackHeight = 8.0;

  @override
  Widget build(BuildContext context) {
    final levels = ExperienceLevel.values;
    final selectedIndex = value?.index;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final step = width / levels.length;
        // Stop centres sit at the middle of each column; the fill runs
        // from the first centre to the chosen one.
        double centreOf(int i) => step * (i + 0.5);

        void selectAt(double dx) {
          final index = (dx / step).floor().clamp(0, levels.length - 1);
          if (levels[index] != value) {
            HapticFeedback.selectionClick();
            onChanged(levels[index]);
          }
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => selectAt(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => selectAt(d.localPosition.dx),
          child: Semantics(
            slider: true,
            value: value?.label ?? 'No rating',
            child: SizedBox(
              height: 84,
              child: Stack(
                children: [
                  // Track.
                  Positioned(
                    left: centreOf(0),
                    right: width - centreOf(levels.length - 1),
                    top: 24 - _trackHeight / 2,
                    height: _trackHeight,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppPalette.hairline,
                        borderRadius: BorderRadius.circular(_trackHeight / 2),
                      ),
                    ),
                  ),
                  // Fill, animated in width and colour.
                  Positioned(
                    left: centreOf(0),
                    top: 24 - _trackHeight / 2,
                    height: _trackHeight,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      width: selectedIndex == null
                          ? 0
                          : centreOf(selectedIndex) - centreOf(0),
                      decoration: BoxDecoration(
                        color: value?.color ?? AppPalette.hairline,
                        borderRadius: BorderRadius.circular(_trackHeight / 2),
                      ),
                    ),
                  ),
                  // Stops with their words.
                  Row(
                    children: [
                      for (final level in levels)
                        Expanded(
                          child: _Stop(
                            level: level,
                            // Everything up to the choice takes the choice's
                            // colour — one reading, not a rainbow of the
                            // levels being passed over.
                            accent: value?.color ?? level.color,
                            state: selectedIndex == null
                                ? _StopState.idle
                                : level.index < selectedIndex
                                ? _StopState.passed
                                : level.index == selectedIndex
                                ? _StopState.selected
                                : _StopState.idle,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

enum _StopState { idle, passed, selected }

class _Stop extends StatelessWidget {
  const _Stop({required this.level, required this.accent, required this.state});

  final ExperienceLevel level;
  final Color accent;
  final _StopState state;

  @override
  Widget build(BuildContext context) {
    final color = accent;
    final selected = state == _StopState.selected;
    final lit = state != _StopState.idle;
    // The springiness lives on the SCALE, not on the AnimatedContainer:
    // an overshooting curve on a lerped BoxShadow drives the blur radius
    // negative and asserts. Transforms tolerate overshoot; decorations
    // do not.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 48,
          child: Center(
            child: AnimatedScale(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutBack,
              scale: selected ? 1 : 0.9,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                width: selected ? 32 : 16,
                height: selected ? 32 : 16,
                decoration: BoxDecoration(
                  color: lit ? color : AppPalette.card,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: lit ? color : AppPalette.textSecondary,
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: selected ? 0.45 : 0),
                      blurRadius: 14,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: selected
                    ? const Icon(
                        Icons.check_rounded,
                        size: 18,
                        color: Colors.white,
                      )
                    : null,
              ),
            ),
          ),
        ),
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 200),
          style: TextStyle(
            color: selected
                ? color
                : lit
                ? color.withValues(alpha: 0.75)
                : AppPalette.textSecondary,
            fontSize: 10.5,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            letterSpacing: 0.3,
            height: 1.1,
          ),
          child: Text(
            level.label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
