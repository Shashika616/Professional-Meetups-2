import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/onboarding/age_confirmation_checkbox.dart';

/// Mandatory, blocking 18+ self-attestation (ADR-014) shown **first**,
/// before any of the four signup paths are even visible — not after
/// picking one, and not per-path. The backend rejects
/// `age_confirmed_over_18 = false` server-side on every signup RPC
/// regardless of what this screen already gated, so this is the primary UX
/// gate (nothing is submitted at all if the box isn't checked), not the
/// only enforcement point.
///
/// No date of birth is collected or stored anywhere — a self-attestation
/// checkbox only, matching ADR-003's minimal-retention spirit.
class AgeConfirmationStep extends StatefulWidget {
  const AgeConfirmationStep({super.key, required this.onContinue});

  /// Called once the box is checked and CONTINUE is tapped — the caller
  /// (`OnboardingFlow`) holds the confirmed value for whichever path the
  /// user picks next.
  final VoidCallback onContinue;

  @override
  State<AgeConfirmationStep> createState() => _AgeConfirmationStepState();
}

class _AgeConfirmationStepState extends State<AgeConfirmationStep> {
  bool _confirmed = false;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      alignment: Alignment.center,
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppPalette.candyBlue.withValues(alpha: 0.3),
                          width: 2,
                        ),
                      ),
                      child: Icon(
                        Icons.shield_outlined,
                        size: 48,
                        color: AppPalette.candyBlue,
                      ),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      'You must be 18 or older\nto use TieHere.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.textPrimary,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 24),
                    AgeConfirmationCheckbox(
                      value: _confirmed,
                      onChanged: (v) => setState(() => _confirmed = v),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'We verify professional identity and give you tools '
                      'to plan safer in-person meetups... But only you can '
                      'judge a situation in the moment. Please use your own '
                      'judgment, meet in public places, and let someone '
                      'know where you’re going.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppPalette.textSecondary.withValues(alpha: 0.85),
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            PrimaryButton(
              label: 'CONTINUE',
              onPressed: _confirmed ? widget.onContinue : null,
            ),
          ],
        ),
      ),
    );
  }
}
