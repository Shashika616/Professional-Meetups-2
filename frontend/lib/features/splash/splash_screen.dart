import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/app_shell.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icon.dart';
import 'package:professional_connections_platform/features/landing/landing_page.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _decideNextScreen();
  }

  Future<void> _decideNextScreen() async {
    final minimumDisplay = Future<void>.delayed(const Duration(seconds: 2));

    // A stored session (i.e. a refresh token) means "logged in" — the short
    // access token being expired doesn't matter here, it refreshes on
    // demand against whatever authenticated call needs it next.
    final sessionState = await ref.read(authSessionProvider.future);

    await minimumDisplay;
    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) =>
            sessionState.isLoggedIn ? const AppShell() : const LandingPage(),
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
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppPalette.onyx, AppPalette.surface, AppPalette.deepBlue],
            stops: [0.0, 0.55, 1.0],
          ),
        ),
        child: SafeArea(
          // Stack rather than one Column: the mark and wordmark belong on the
          // optical centre of the screen, while the attribution belongs on the
          // bottom edge. Putting both in a single centred Column would drag
          // the logo upward by however tall the attribution is.
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const AppIcon(size: 170, radius: 40, glow: true),
                    const SizedBox(height: 30),
                    // The wordmark, set exactly as the landing hero and the
                    // brand sheet set it - mixed case, "Here" in the brand
                    // green. The old splash shouted PROFESSIONAL\nCONNECTIONS
                    // in tracked-out caps, which is not how this logo reads.
                    RichText(
                      textAlign: TextAlign.center,
                      text: TextSpan(
                        style: TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.6,
                          height: 1.05,
                          color: AppPalette.textPrimary,
                        ),
                        children: [
                          const TextSpan(text: 'Tie'),
                          TextSpan(
                            text: 'Here',
                            style: TextStyle(color: AppPalette.brandGreen),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      "Connect with who's here",
                      style: TextStyle(
                        fontSize: 12.5,
                        color: AppPalette.textSecondary,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 40),
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppPalette.candyBlue.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              // Maker's mark, bottom-centre, in the place WhatsApp and
              // Facebook put theirs. Quiet on purpose: it is a signature, not
              // a second brand competing with the one above it.
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 26),
                  child: RichText(
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text: 'From ',
                          style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 1.4,
                            color: AppPalette.textSecondary.withValues(
                              alpha: 0.75,
                            ),
                          ),
                        ),
                        TextSpan(
                          // U+00B7 MIDDLE DOT on each side, not full stops -
                          // these are part of the mark, not sentence
                          // punctuation, and a period here would read as the
                          // end of a sentence that never started.
                          text: '\u00B7SAI\u00B7',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2.2,
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
            ],
          ),
        ),
      ),
    );
  }
}
