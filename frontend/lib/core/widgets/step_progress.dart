import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The segmented bar at the top of a multi-step flow: one short bar per
/// step, filled up to where you are.
///
/// # WHY SEGMENTS AND NOT ONE CONTINUOUS BAR
///
/// A single bar at 60% tells you how far along you are but not how much is
/// left in units you can count. Five bars with three filled says "two more
/// screens", which is the question someone actually has in the middle of a
/// scheduling flow. It is also what makes the "Step 3 of 5" caption above
/// it honest rather than decorative — the two are showing the same thing.
class StepProgress extends StatelessWidget {
  const StepProgress({
    super.key,
    required this.total,
    required this.current,
    this.height = 4,
  });

  final int total;

  /// 1-based: `current == 1` fills the first segment.
  final int current;

  final double height;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      // Announced as one value, not as N anonymous bars.
      label: 'Step $current of $total',
      excludeSemantics: true,
      child: Row(
        children: [
          for (var i = 1; i <= total; i++) ...[
            if (i > 1) const SizedBox(width: 4),
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                height: height,
                decoration: BoxDecoration(
                  color: i <= current ? AppPalette.verified : AppPalette.track,
                  borderRadius: BorderRadius.circular(height / 2),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The two-step variant used by the review flow, where the steps are
/// shown as a short pill and a long one rather than as equal segments.
///
/// Equal segments imply equal weight, and these two steps are not equal:
/// rating the meetup is one slider, rating the people is a list. The
/// widths say which one you are in without a caption.
class ProgressPills extends StatelessWidget {
  const ProgressPills({super.key, required this.total, required this.current});

  final int total;

  /// 1-based.
  final int current;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Step $current of $total',
      excludeSemantics: true,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 1; i <= total; i++) ...[
            if (i > 1) const SizedBox(width: 6),
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              height: 4,
              width: i == current ? 26 : 10,
              decoration: BoxDecoration(
                color: i == current ? AppPalette.steelBlue : AppPalette.track,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
