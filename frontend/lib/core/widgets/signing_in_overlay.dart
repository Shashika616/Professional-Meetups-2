import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

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
        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
        child: Material(
          type: MaterialType.transparency,
          child: ColoredBox(
            color: AppPalette.onyx.withValues(alpha: 0.45),
            child: Center(child: _ProgressCard(message: message)),
          ),
        ),
      ),
    );
  }
}

/// A small surface with a slim ring and one line, the shape of a system
/// progress dialog: nothing decorative, nothing to read twice.
class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 24, 16),
      decoration: BoxDecoration(
        color: AppPalette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppPalette.hairline),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: AppPalette.isLight ? 0.10 : 0.35,
            ),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              strokeCap: StrokeCap.round,
              color: AppPalette.brandGreen,
              backgroundColor: AppPalette.brandGreen.withValues(alpha: 0.15),
            ),
          ),
          const SizedBox(width: 14),
          Text(
            message,
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}
