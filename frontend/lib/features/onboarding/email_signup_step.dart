import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/glass_text_field.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/verification/widgets/otp_entry.dart';

enum _Step { email, otp }

/// Email-OTP signup, no password anywhere (ADR-019 §1) — email field →
/// `startEmailSignupOtp` → OTP entry (reusing [OtpEntry], the same widget
/// phone/personal-email verification already use, not a rebuild) →
/// `signUpWithEmail`, which both verifies the code and creates the account
/// server-side in one `CompleteEmailSignup` call.
///
/// Pops `true` on a successful signup so the caller (`OnboardingFlow`)
/// knows to proceed; pops nothing (`null`) if the user backs out.
class EmailSignupStep extends ConsumerStatefulWidget {
  const EmailSignupStep({super.key, required this.ageConfirmedOver18});

  final bool ageConfirmedOver18;

  @override
  ConsumerState<EmailSignupStep> createState() => _EmailSignupStepState();
}

class _EmailSignupStepState extends ConsumerState<EmailSignupStep> {
  _Step _step = _Step.email;
  final _emailController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _emailController.addListener(_onFieldChanged);
  }

  void _onFieldChanged() => setState(() {});

  @override
  void dispose() {
    _emailController.removeListener(_onFieldChanged);
    _emailController.dispose();
    super.dispose();
  }

  bool get _emailLooksValid => _emailController.text.trim().contains('@');

  // Optimistic transition (UX improvement) — flips to the OTP entry screen
  // immediately, instead of waiting on the network call first; OtpEntry
  // sends the code itself once mounted, via [_startSignupOtp], and shows
  // its own optimistic countdown/loading/error state for that — see
  // OtpEntry's own doc comment for why a slow or failing backend no longer
  // stalls this screen.
  void _showOtp() {
    if (!_emailLooksValid) return;
    setState(() => _step = _Step.otp);
  }

  Future<int> _startSignupOtp() => ref
      .read(authServiceProvider)
      .startEmailSignupOtp(_emailController.text.trim());

  // No local try/catch — a failure (wrong/expired code, etc.) propagates
  // to OtpEntry's own error handling, which shows it inline (same
  // convention as PhoneVerificationPage/PersonalEmailVerificationPage's
  // own `_verify`). Unauthenticated call, so there's no
  // SessionExpiredException case to special-case here either.
  Future<void> _onOtpEntered(String code) async {
    await ref
        .read(authSessionProvider.notifier)
        .signUpWithEmail(
          email: _emailController.text.trim(),
          code: code,
          ageConfirmedOver18: widget.ageConfirmedOver18,
        );
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      // Without this, the AppBar's own (transparent) region isn't covered
      // by AppBackground at all — body painting starts below the app bar,
      // so that strip shows through to nothing but plain black instead of
      // the same image/gradient as the rest of the screen. This also
      // widens MediaQuery's top padding to include the app bar's height,
      // so the SafeArea below still pushes content clear of the title row.
      // Same fix as profile_setup_screen.dart's identical Scaffold shape.
      extendBodyBehindAppBar: true,
      appBar: AppBar(title: const Text('SIGN UP WITH EMAIL')),
      body: AppBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: switch (_step) {
              _Step.email => _emailStep(),
              _Step.otp => _otpStep(),
            },
          ),
        ),
      ),
    );
  }

  Widget _emailStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(
          'What’s your email?',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: AppPalette.textPrimary,
          ),
        ),
        const SizedBox(height: 20),
        GlassTextField(
          controller: _emailController,
          icon: Icons.alternate_email_rounded,
          hint: 'you@example.com',
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 16),
        PrimaryButton(
          label: 'SEND CODE',
          onPressed: _emailLooksValid ? _showOtp : null,
        ),
      ],
    );
  }

  Widget _otpStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(
          'Enter the code we sent to ${_emailController.text.trim()}',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppPalette.textPrimary,
          ),
        ),
        const SizedBox(height: 20),
        OtpEntry(onSend: _startSignupOtp, onSubmit: _onOtpEntered),
      ],
    );
  }
}
