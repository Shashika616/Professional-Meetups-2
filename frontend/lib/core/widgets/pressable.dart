import 'package:flutter/material.dart';

/// Press feedback for a whole card, row or tile the user taps to go
/// somewhere (Plan 23, Finding 1).
///
/// Before this, the app's tappable cards were bare `GestureDetector`s: a tap
/// produced nothing at all on screen until whatever `onTap` did — usually a
/// page push — finished building. Apple's own first rule of interaction is
/// to respond on pointer-DOWN rather than on release, because the moment
/// that lag appears the surface stops feeling like a thing you are touching
/// and starts feeling like a form you are submitting. [PrimaryButton] was
/// the only widget in this app already doing it right; this is the same
/// feedback, for the things that are not buttons.
///
/// # WHY 0.98 AND NOT [PrimaryButton]'S 1.02
///
/// Direction carries meaning here. A button is small and sits ON the page,
/// so growing slightly under the finger reads as it rising to meet you. A
/// card IS the page's surface at that spot — often nearly full width — and
/// a large rectangle swelling past its own margins reads as a glitch, not a
/// press. Pressing IN is the physical gesture a card affords, so the scale
/// goes the other way. The magnitude, duration and curve are deliberately
/// identical to [PrimaryButton]'s otherwise: this is meant to feel like one
/// system, not two.
///
/// Deliberately a separate widget rather than a refactor of
/// [PrimaryButton]: that button's press state is entangled with its
/// loading/disabled states and its `Ink`/`InkWell` fill, and folding the
/// two together would complicate the button to share about six lines.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, required this.onTap});

  final Widget child;

  /// Null means disabled, the same convention as `PrimaryButton.onPressed`:
  /// no tap fires, and no press feedback is shown either, so a dead card
  /// never animates as though it were about to do something.
  final VoidCallback? onTap;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _isPressed = false;

  void _onTapDown(TapDownDetails details) {
    if (widget.onTap != null) {
      setState(() => _isPressed = true);
    }
  }

  void _onTapUp(TapUpDetails details) {
    if (mounted) setState(() => _isPressed = false);
  }

  void _onTapCancel() {
    if (mounted) setState(() => _isPressed = false);
  }

  @override
  Widget build(BuildContext context) {
    // Same early return as `Shimmer` (core/widgets/skeleton_loader.dart),
    // on purpose: someone who asked the OS for less motion gets the tap and
    // the card, just not the movement. One pattern for reduced motion in
    // this codebase, not two.
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      // Plain `onTap`, unchanged semantics: it still fires on release inside
      // the bounds and not at all if the finger slides off first. This
      // widget adds a visual response to the press; it does not move when a
      // tap counts as a tap.
      onTap: widget.onTap,
      child: reduceMotion
          ? widget.child
          : AnimatedScale(
              scale: _isPressed ? 0.98 : 1.0,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: widget.child,
            ),
    );
  }
}
