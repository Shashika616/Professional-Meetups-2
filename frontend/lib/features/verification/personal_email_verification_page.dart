import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/validation/validators.dart';
import 'package:professional_connections_platform/core/widgets/glass_text_field.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/verification/widgets/otp_entry.dart';
import 'package:professional_connections_platform/features/verification/widgets/verification_scaffold.dart';

/// Personal email entry → shared OTP widget. Reachable both from the
/// post-LinkedIn onboarding sequence and independently from `ProfilePage`
/// (`frontend/PLAN.md`'s Level 2/3 addendum, Step 6).
///
/// [currentValue] (ADR-023 §5) is the real, already-verified email —
/// passed when this screen is opened to *edit* an already-verified row
/// (`ProfilePage`), null for a genuine first-time verification. Shown
/// pre-filled and fully editable; it is never resubmitted as-is — SEND CODE
/// always runs a fresh OTP round-trip against whatever value is in the
/// field when tapped, identical to first-time verification.
class PersonalEmailVerificationPage extends ConsumerStatefulWidget {
  const PersonalEmailVerificationPage({super.key, this.currentValue});

  final String? currentValue;

  @override
  ConsumerState<PersonalEmailVerificationPage> createState() =>
      _PersonalEmailVerificationPageState();
}

class _PersonalEmailVerificationPageState
    extends ConsumerState<PersonalEmailVerificationPage> {
  final _emailController = TextEditingController();
  bool _showOtpEntry = false;

  @override
  void initState() {
    super.initState();
    if (widget.currentValue != null) {
      _emailController.text = widget.currentValue!;
    }
    // GlassTextField doesn't expose onChanged — listening on the
    // controller directly is what makes SEND CODE react as the user types.
    _emailController.addListener(_onFieldChanged);
  }

  void _onFieldChanged() => setState(() {});

  @override
  void dispose() {
    _emailController.removeListener(_onFieldChanged);
    _emailController.dispose();
    super.dispose();
  }

  String get _email => _emailController.text.trim();

  // Optimistic transition (UX improvement) — flips to the OTP entry screen
  // immediately, instead of waiting on the network call first; OtpEntry
  // sends the code itself once mounted, via [_startVerification], and
  // shows its own optimistic countdown/loading/error state for that — see
  // OtpEntry's own doc comment for why a slow or failing backend no longer
  // stalls this screen.
  void _showOtp() {
    if (_showOtpEntry || Validators.email(_email) != null) return;
    setState(() => _showOtpEntry = true);
  }

  Future<int> _startVerification() async {
    try {
      return await ref
          .read(authServiceProvider)
          .startPersonalEmailVerification(_email);
    } on SessionExpiredException {
      // No local error shown here — AppShell's listener navigates to
      // LandingPage and shows the "session expired" message itself;
      // rethrown so OtpEntry's own catch doesn't also surface a redundant
      // generic message.
      if (mounted) ref.read(authSessionProvider.notifier).forceSignOut();
      rethrow;
    }
  }

  Future<void> _verify(String code) async {
    try {
      final session = await ref
          .read(authServiceProvider)
          .verifyPersonalEmailCode(_email, code);
      await ref
          .read(authSessionProvider.notifier)
          .completeVerification(session);
      if (!mounted) return;
      Navigator.pop(context);
    } on SessionExpiredException {
      // Rethrown so OtpEntry's own catch still surfaces the (specific,
      // non-generic) message while AppShell's listener navigates away.
      if (mounted) ref.read(authSessionProvider.notifier).forceSignOut();
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return VerificationScaffold(
      icon: Icons.email_outlined,
      headline: 'Verify Your Email',
      trustBenefit:
          'A verified personal email gives you an account-recovery path '
          'that doesn\'t depend on LinkedIn or your phone.',
      onSkip: () => Navigator.pop(context),
      child: !_showOtpEntry
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GlassTextField(
                  controller: _emailController,
                  icon: Icons.email_outlined,
                  hint: 'you@example.com',
                  keyboardType: TextInputType.emailAddress,
                  validator: (_) => Validators.email(_email),
                ),
                const SizedBox(height: 16),
                PrimaryButton(
                  label: 'SEND CODE',
                  onPressed: Validators.email(_email) == null ? _showOtp : null,
                ),
              ],
            )
          : OtpEntry(onSend: _startVerification, onSubmit: _verify),
    );
  }
}
