import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icon.dart';

/// Covers a page while a sign-in or sign-up is in flight: the page blurs
/// and dims, every control under it stops taking taps, and one loader with
/// the app's mark says what is happening.
///
/// # WHY A PAGE-LEVEL OVERLAY
///
/// The Google/Apple and LinkedIn buttons share one busy flag, and both used
/// to show a spinner while either provider ran, so a tap on Google made
/// LinkedIn spin too. Two spinning buttons read as two things happening. A
/// single overlay says one thing is happening, blocks the whole page
/// (including the app bar's back button and the age checkbox, which the
/// per-button flags could not reach), and is the same on the sign-up and
/// sign-in doors.
///
/// Wrap the [Scaffold], not just its body, so the app bar is covered too.
class SigningInOverlay extends StatelessWidget {
  const SigningInOverlay({
    super.key,
    required this.busy,
    required this.child,
    this.message = 'Signing you in',
  });

  final bool busy;
  final Widget child;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        // IgnorePointer only while hidden, so a finished sign-in hands the
        // page back the moment the fade starts rather than after it ends.
        //
        // Appears in one frame, fades out over 220 ms. A provider flow
        // hands off to the browser or an account sheet within a frame or
        // two of the tap, and Flutter stops drawing while it is behind
        // them, so a fade-IN would freeze at its first, invisible frame
        // and the page would come back from the provider un-veiled.
        IgnorePointer(
          ignoring: !busy,
          child: AnimatedOpacity(
            opacity: busy ? 1 : 0,
            duration: busy ? Duration.zero : const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            child: busy ? _Veil(message: message) : const SizedBox.expand(),
          ),
        ),
      ],
    );
  }
}

class _Veil extends StatelessWidget {
  const _Veil({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    // The veil sits ABOVE the page's Scaffold, so nothing gives its text a
    // Material ancestor; without one the labels render in the framework's
    // fallback face with the yellow double underline. A transparent
    // Material supplies the text style and paints nothing itself.
    return Semantics(
      liveRegion: true,
      label: message,
      child: BackdropFilter(
        key: const Key('signingInOverlay'),
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Material(
          type: MaterialType.transparency,
          child: ColoredBox(
            color: AppPalette.onyx.withValues(
              alpha: AppPalette.isLight ? 0.6 : 0.62,
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _MarkInRing(),
                  const SizedBox(height: 22),
                  Text(
                    message,
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Just a moment',
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The launcher mark at rest inside a thin brand-green arc that sweeps
/// around it, over a soft glow. The arc is the "still working" signal; the
/// mark is so the wait belongs to this app and not to whichever provider's
/// sheet just closed. Proportions: mark 56, a breath of space, then a
/// 4-point ring at 92: thick enough to read as a made object rather than a
/// hairline, with enough air that it is not an icon jammed in a spinner.
class _MarkInRing extends StatelessWidget {
  const _MarkInRing();

  static const double _ring = 92;
  static const double _mark = 56;

  @override
  Widget build(BuildContext context) {
    final green = AppPalette.brandGreen;
    return SizedBox(
      width: _ring + 32,
      height: _ring + 32,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Glow: a soft radial wash so the mark sits in light rather than
          // on a flat scrim.
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  green.withValues(alpha: 0.22),
                  green.withValues(alpha: 0.0),
                ],
                stops: const [0.35, 1],
              ),
            ),
            child: const SizedBox.square(dimension: _ring + 32),
          ),
          // Track, faint, so the arc has something to travel along.
          SizedBox.square(
            dimension: _ring,
            child: CircularProgressIndicator(
              value: 1,
              strokeWidth: 4,
              color: green.withValues(alpha: 0.16),
            ),
          ),
          // The sweeping arc.
          SizedBox.square(
            dimension: _ring,
            child: CircularProgressIndicator(
              strokeWidth: 4,
              strokeCap: StrokeCap.round,
              color: green,
            ),
          ),
          // A plate under the mark so its own white or dark tile has a
          // clean edge against the blur.
          Container(
            width: _mark + 12,
            height: _mark + 12,
            decoration: BoxDecoration(
              color: AppPalette.surface,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: AppPalette.isLight ? 0.10 : 0.40,
                  ),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
          ),
          const AppIcon(size: _mark, radius: 14),
        ],
      ),
    );
  }
}
