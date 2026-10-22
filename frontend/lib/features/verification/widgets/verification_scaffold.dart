import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_back_button.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';

/// Shared page chrome for all four Level 2/3 verification screens — icon,
/// headline, a "Skip for now" action, then whatever screen-specific body
/// [child] is (phone/email entry, [OtpEntry], or the personal-details
/// form). Keeps the four screens visually identical without duplicating
/// this structure four times over (`frontend/PLAN.md`'s Level 2/3
/// addendum, Step 4: "no new visual language for these four screens").
///
/// # THE TRUST-BENEFIT PARAGRAPH IS GONE
///
/// Every one of these screens carried three lines of prose under the
/// headline explaining why verifying was worth it — "unlocks messaging
/// other members and helps keep the community scam-resistant", and so on.
/// Nobody arriving at an OTP screen is deciding whether to believe in
/// verification; they got here by tapping something that said they would
/// verify. The paragraph pushed the one field below the fold on a small
/// phone and made four near-identical screens each feel like a pitch.
/// The headline states the task and the field is directly under it.
class VerificationScaffold extends StatelessWidget {
  const VerificationScaffold({
    super.key,
    required this.icon,
    required this.headline,
    required this.child,
    required this.onSkip,
  });

  final String icon;
  final String headline;
  final Widget child;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // These four pages (phone, personal email, corporate email,
                // personal details) had NO back control at all — only this
                // "Skip for now" in the opposite corner. Skipping is not the
                // same as going back: it is a decision about the step, and a
                // user who opened the wrong one had nothing to tap. On
                // Android the system gesture still worked, which is exactly
                // how a missing affordance stays missing for a year.
                Row(
                  children: [
                    const AppBackButton(),
                    const Spacer(),
                    TextButton(
                      onPressed: onSkip,
                      child: Text(
                        'Skip for now',
                        style: TextStyle(
                          color: AppPalette.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
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
                    child: AppIcon(icon, size: 48, color: AppPalette.candyBlue),
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
