import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/landing_collage.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/features/auth/email_login_page.dart';
import 'package:professional_connections_platform/features/onboarding/onboarding_flow.dart';

class LandingPage extends StatefulWidget {
  const LandingPage({super.key, this.sessionExpired = false});

  /// True when this page was reached via AppShell's involuntary-sign-out
  /// safety net (`frontend/PLAN.md`'s "Session refresh wiring fix"
  /// addendum, Step 5) rather than a normal cold start or a voluntary sign
  /// out — shows a brief explanation once, so the redirect doesn't read as
  /// an unexplained kick-out.
  final bool sessionExpired;

  @override
  State<LandingPage> createState() => _LandingPageState();
}

class _LandingPageState extends State<LandingPage> {
  @override
  void initState() {
    super.initState();
    if (widget.sessionExpired) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showSnack(
            context,
            'Your session expired... Please sign in again.',
            type: ToastType.warning,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.onyx,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // The backdrop occupies the whole page rather than a top band. The
          // scrim below is what creates the band, and doing it that way means
          // the boundary is a gradient rather than a hard edge where the
          // images stop.
          const RepaintBoundary(child: LandingCollage()),

          // Two layers, both needed, and the split between them is the point.
          //
          // The flat tint only has to take the EDGE off the artwork so it
          // reads as a backdrop rather than as content. The first pass set it
          // to 0.58, which on light mode means a 58% wash of a near white
          // colour: the images went to nothing and the page looked broken
          // rather than restrained. Light needs far less than dark, because
          // dark text over pale artwork is already the harder contrast case
          // and the wash was fighting it from both sides.
          Positioned.fill(
            child: ColoredBox(
              color: AppPalette.onyx.withValues(
                alpha: AppPalette.isLight ? 0.26 : 0.46,
              ),
            ),
          ),
          // The gradient does the actual work: it leaves the top legible and
          // buries the bottom completely, so the wordmark and CTA sit on solid
          // colour and never have to survive whatever image is behind them.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.18, 0.46, 0.68, 1.0],
                  colors: [
                    // A little weight at the very top so the status bar
                    // stays readable over whatever scrolls past under it.
                    AppPalette.onyx.withValues(alpha: 0.55),
                    AppPalette.onyx.withValues(alpha: 0.12),
                    AppPalette.onyx.withValues(alpha: 0.40),
                    AppPalette.onyx.withValues(alpha: 0.94),
                    AppPalette.onyx,
                  ],
                ),
              ),
            ),
          ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  const Spacer(),
                  _wordmark(),
                  const SizedBox(height: 26),
                  PrimaryButton(
                    label: 'GET STARTED',
                    icon: Icons.arrow_forward_rounded,
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => const OnboardingFlow(),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => const EmailLoginPage(),
                      ),
                    ),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: 'ALREADY A MEMBER?   ',
                            style: TextStyle(
                              fontSize: 10,
                              letterSpacing: 1.6,
                              fontWeight: FontWeight.w700,
                              color: AppPalette.textSecondary,
                            ),
                          ),
                          TextSpan(
                            text: 'SIGN IN',
                            style: TextStyle(
                              fontSize: 10,
                              letterSpacing: 1.6,
                              fontWeight: FontWeight.w900,
                              color: AppPalette.candyBlue,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The name, the tagline, and nothing else.
  ///
  /// The orbiting intent chips and the "VERIFIED PROFESSIONALS" pill that used
  /// to fill this space are gone. Both existed to give an empty page something
  /// to look at; the backdrop does that now, and leaving them in would have
  /// been three competing things in one view.
  Widget _wordmark() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            style: TextStyle(
              fontSize: 44,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.0,
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
        const SizedBox(height: 12),
        Text(
          "Connect with who's here",
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 15,
            height: 1.4,
            color: AppPalette.textSecondary,
          ),
        ),
      ],
    );
  }
}
