import 'dart:async';

import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/widgets/ambient_animation.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The two things every loading placeholder in this app needs, in one
/// wrapper: it waits before showing anything, and what it shows moves.
///
/// # WHY IT WAITS ([delay])
///
/// A placeholder that appears for one or two frames is worse than no
/// placeholder at all — the user perceives a flash, not loading. That is
/// exactly the "gets all grey and then loads" report that led here: a
/// genuinely fast fetch still rendered a full skeleton for a frame on its
/// way past.
///
/// So nothing is drawn for the first [delay]. If the data arrives inside
/// that window — a warm cache, a fast connection, an already-resolved
/// provider — this widget is disposed before it ever paints and the user
/// sees content appear directly. Only a load slow enough to actually notice
/// gets a placeholder, which is the only case one helps.
///
/// 180ms is the usual figure for this (comfortably under the ~250ms at which
/// a wait starts to feel like a wait, comfortably over a few frames).
///
/// # WHY IT MOVES ([Shimmer])
///
/// A static grey block is indistinguishable from a rendering glitch. Motion
/// is what signals "this is deliberate, content is coming" — which is why
/// `SkeletonBox`'s own comments always called this a shimmer even while it
/// was a plain, motionless `Container`.
///
/// # BOTH THEMES
///
/// Neither half hardcodes a colour. The boxes tint with
/// `AppPalette.textPrimary` (near-white on dark, near-black on light) and the
/// sweep is derived from the same token, so this reads correctly in dark and
/// light without a second code path.
class SkeletonLoader extends StatefulWidget {
  const SkeletonLoader({super.key, required this.child, this.delay = _default});

  final Widget child;

  /// How long to show nothing before conceding that this is a real wait.
  final Duration delay;

  static const _default = Duration(milliseconds: 180);

  @override
  State<SkeletonLoader> createState() => _SkeletonLoaderState();
}

class _SkeletonLoaderState extends State<SkeletonLoader> {
  bool _visible = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didUpdateWidget(SkeletonLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.delay != widget.delay) {
      _timer?.cancel();
      _startTimer();
    }
  }

  void _startTimer() {
    if (widget.delay == Duration.zero) {
      _visible = true;
      return;
    }
    _timer = Timer(widget.delay, () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    // Load finished inside the delay window: the timer never fires, nothing
    // is ever painted, and there is no flash to see. That is the common
    // case, and cancelling here is what makes it free.
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    return Shimmer(child: widget.child);
  }
}

/// Sweeps a soft highlight across everything beneath it.
///
/// # ONE CONTROLLER, NOT ONE PER BOX
///
/// A skeleton is a dozen or more `SkeletonBox`es. Animating each one
/// separately would mean a dozen tickers and — worse — a dozen sweeps out of
/// phase with each other, which looks like noise rather than a single
/// surface catching the light. Painting one gradient across the whole
/// subtree is both cheaper and the thing that actually reads as polished.
///
/// [BlendMode.srcATop] confines the sweep to pixels the child already
/// painted, so it brightens the placeholder blocks and leaves the gaps
/// between them alone.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});

  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Respects the OS "reduce motion" setting. Someone who has asked the
    // system for less animation should get a still placeholder, not an
    // exception to their own preference — and it keeps the placeholder
    // fully legible either way.
    if (debugDisableAmbientAnimations ||
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      return widget.child;
    }

    // The sweep is the SAME token the boxes are tinted with, so it inherits
    // their theme adaptation instead of duplicating it. Light mode needs the
    // stronger value for the same reason SkeletonBox boosts its own alpha
    // there: an equal alpha reads far fainter against a bright ground.
    final highlight = AppPalette.textPrimary.withValues(
      alpha: AppPalette.isLight ? 0.16 : 0.10,
    );

    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        // Travels from fully off one edge to fully off the other, so the
        // band is never parked on screen at either end of a cycle.
        final t = _controller.value * 2 - 0.5;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [Colors.transparent, highlight, Colors.transparent],
            stops: [
              (t - 0.25).clamp(0.0, 1.0),
              t.clamp(0.0, 1.0),
              (t + 0.25).clamp(0.0, 1.0),
            ],
          ).createShader(bounds),
          child: child,
        );
      },
    );
  }
}
