import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_icon.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/features/auth/email_login_page.dart';
import 'package:professional_connections_platform/features/landing/widgets/orbiting_intents.dart';
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
      backgroundColor: Colors.transparent,
      body: AppBackground(
        imageOpacity: 0.5,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              children: [
                const SizedBox(height: 12),
                _topBar(),
                Expanded(child: _hero()),
                _taglinePill(),
                const SizedBox(height: 16),
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
                const SizedBox(height: 14),
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
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    return Row(
      children: [
        SizedBox(width: 10),
        Expanded(
          child: Text(
            'PROFESSIONAL CONNECTIONS',
            style: TextStyle(
              fontSize: 9,
              letterSpacing: 2.2,
              fontWeight: FontWeight.w800,
              color: AppPalette.textPrimary,
            ),
          ),
        ),
        Icon(Icons.language_rounded, size: 16, color: AppPalette.textSecondary),
      ],
    );
  }

  Widget _hero() {
    return Stack(
      alignment: Alignment.center,
      children: [
        OrbitingIntents(),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(size: 92, glow: true),
              SizedBox(height: 18),
              Text(
                'CONNECT BEYOND\nTHE OFFICE.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: AppPalette.textPrimary,
                  height: 1.2,
                  letterSpacing: -0.5,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'Meet verified professionals in real life.',
                style: TextStyle(fontSize: 13, color: AppPalette.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _taglinePill() {
    return FlatCard(
      radius: 12,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Text(
              'VERIFIED PROFESSIONALS | REAL CONNECTIONS',
              textAlign: TextAlign.center,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 9,
                letterSpacing: 1.6,
                fontWeight: FontWeight.w700,
                color: AppPalette.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
