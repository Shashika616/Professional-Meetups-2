import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';

/// Shared page chrome for all four Level 2/3 verification screens — icon,
/// headline, trust-benefit line, a "Skip for now" action, then whatever
/// screen-specific body [child] is (phone/email entry, [OtpEntry], or the
/// personal-details form). Keeps the four screens visually identical
/// without duplicating this structure four times over
/// (`frontend/PLAN.md`'s Level 2/3 addendum, Step 4: "no new visual
/// language for these four screens").
class VerificationScaffold extends StatelessWidget {
  const VerificationScaffold({
    super.key,
    required this.icon,
    required this.headline,
    required this.trustBenefit,
    required this.child,
    required this.onSkip,
  });

  final IconData icon;
  final String headline;
  final String trustBenefit;
  final Widget child;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        imageOpacity: 0.35,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: TextButton(
                    onPressed: onSkip,
                    child: Text(
                      'Skip for now',
                      style: TextStyle(
                        color: AppPalette.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppPalette.candyBlue.withValues(alpha: 0.3),
                        width: 2,
                      ),
                    ),
                    child: Icon(icon, size: 48, color: AppPalette.candyBlue),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  headline,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: AppPalette.textPrimary,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  trustBenefit,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppPalette.textSecondary.withValues(alpha: 0.85),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 28),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
