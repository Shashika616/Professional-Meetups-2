import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/utils/reduced_motion.dart';
import 'package:professional_connections_platform/core/widgets/brand_loader.dart';
import 'package:professional_connections_platform/core/analytics/screen_names.dart';
import 'package:professional_connections_platform/app_shell.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/features/landing/landing_page.dart';
import 'package:professional_connections_platform/features/splash/splash_art.dart';

/// How long the mark and the name take to build.
const _assembleDuration = Duration(milliseconds: 1500);

/// The way out, in two steps that do not overlap: the same animation
/// backwards on the plain ground, then the next screen fades in.
const _exitDuration = Duration(milliseconds: 1300);

/// Where in [_exitDuration] the mark has gone and the fade begins.
const _exitSplit = 0.78;

const _tagline = "Connect with who's here";

/// The mark, the name and the tagline, centred on the full screen. The
/// splash and the way out both draw this, so the reverse starts exactly where
/// the build ended.
class _Lockup extends StatelessWidget {
  const _Lockup({required this.progress, this.waiting = false});

  final Animation<double> progress;
  final bool waiting;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SplashArt(progress: progress),
          SizedBox(
            height: 22,
            child: FadeTransition(
              opacity: CurvedAnimation(
                parent: progress,
                curve: const Interval(0.8, 1, curve: Curves.easeOut),
              ),
              child: Text(
                _tagline,
                style: TextStyle(
                  fontSize: 13,
                  color: AppPalette.textSecondary,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
          const SizedBox(height: 26),
          // Only when the app is slower than the animation: a launch that
          // is on time never shows a spinner.
          SizedBox(
            width: 28,
            height: 28,
            child: waiting ? const BrandLoader(size: 28) : null,
          ),
        ],
      ),
    );
  }
}

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _assemble = AnimationController(
    vsync: this,
    duration: _assembleDuration,
  );
  bool _started = false;
  bool _waiting = false;

  /// True once the reverse is on screen: the art is then drawn by the next
  /// route, above the page fading in.
  bool _breaking = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // Reduce motion: the finished mark from the first frame, and a plain fade
    // out of it.
    final still = reducedMotion(context);
    if (still) {
      _assemble.value = 1;
    } else {
      _assemble.forward();
    }
    _decideNextScreen(still: still);
  }

  @override
  void dispose() {
    _assemble.dispose();
    super.dispose();
  }

  Future<void> _decideNextScreen({required bool still}) async {
    final minimumDisplay = Future<void>.delayed(const Duration(seconds: 2));

    // A stored session (i.e. a refresh token) means "logged in" — the short
    // access token being expired doesn't matter here, it refreshes on
    // demand against whatever authenticated call needs it next.
    final session = ref.read(authSessionProvider.future);
    await minimumDisplay;
    if (!mounted) return;
    final slow = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _waiting = true);
    });
    final sessionState = await session;
    slow.cancel();
    if (!mounted) return;

    setState(() => _waiting = false);
    // The art stays up until the next route has painted, which draws it
    // again above the page, so no frame is ever empty.
    if (!still) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _breaking = true);
      });
    }
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        settings: RouteSettings(
          name: sessionState.isLoggedIn
              ? ScreenNames.appShell
              : ScreenNames.landing,
        ),
        transitionDuration: still
            ? const Duration(milliseconds: 220)
            : _exitDuration,
        pageBuilder: (context, _, _) =>
            sessionState.isLoggedIn ? const AppShell() : const LandingPage(),
        transitionsBuilder: (context, animation, _, child) => Stack(
          fit: StackFit.expand,
          children: [
            FadeTransition(
              opacity: animation.drive(
                CurveTween(
                  curve: Interval(
                    still ? 0 : _exitSplit,
                    1,
                    curve: Curves.easeOut,
                  ),
                ),
              ),
              child: child,
            ),
            if (!still)
              IgnorePointer(
                child: AnimatedBuilder(
                  animation: animation,
                  builder: (context, _) => animation.isCompleted
                      ? const SizedBox.shrink()
                      : _Lockup(
                          progress: ReverseAnimation(
                            animation.drive(
                              CurveTween(curve: const Interval(0, _exitSplit)),
                            ),
                          ),
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        // Themeable, reliably-findable widget (Slice G's
        // theme_toggle_test.dart samples this key's rendered color to
        // verify the app-wide theme rebuild mechanism actually works) —
        // SplashScreen is always the first thing on screen, so it's a
        // convenient, stable target regardless of what's pushed after it.
        key: const ValueKey('splash-gradient-container'),
        width: double.infinity,
        height: double.infinity,
        // The app's own ground, so the splash hands over to the first
        // screen without a colour change.
        decoration: BoxDecoration(gradient: AppPalette.backgroundGradient),
        child: Stack(
          children: [
            if (!_breaking) _Lockup(progress: _assemble, waiting: _waiting),
            // Maker's mark, bottom-centre, in the place WhatsApp and Facebook
            // put theirs. Quiet on purpose: it is a signature, not a second
            // brand competing with the one above it.
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 26),
                  child: FadeTransition(
                    opacity: CurvedAnimation(
                      parent: _assemble,
                      curve: const Interval(0.8, 1, curve: Curves.easeOut),
                    ),
                    child: RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: 'From ',
                            style: TextStyle(
                              fontSize: 11,
                              letterSpacing: 0.3,
                              color: AppPalette.textSecondary,
                            ),
                          ),
                          TextSpan(
                            text: 'AshiruLabs',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.4,
                              color: AppPalette.textPrimary.withValues(
                                alpha: 0.85,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
