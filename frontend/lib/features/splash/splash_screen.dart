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
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Big, professional, glowing app icon (no forced circle)
              const AppIcon(size: 170, radius: 40, glow: true),
              const SizedBox(height: 28),
              Text(
                'PROFESSIONAL\nCONNECTIONS',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 3.0,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Connect Beyond the Office.',
                style: TextStyle(fontSize: 12, color: AppPalette.textSecondary),
              ),
              const SizedBox(height: 44),
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
      ),
    );
  }
}
