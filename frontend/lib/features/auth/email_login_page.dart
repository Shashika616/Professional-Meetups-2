import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/app_shell.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/glass_text_field.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/verification/widgets/otp_entry.dart';

enum _Step { email, otp }

/// Email-OTP sign-in for a returning user (ADR-019 §1) — the one path that
/// genuinely can't collapse "resolve or create" into a single tap the way
/// Apple/Google/LinkedIn do, so it gets its own form, reached from
/// [LandingPage]'s "Sign in" link — distinct from [OnboardingFlow]'s entry
/// screen, which is for new sign-ups. No password anywhere, ever: every
/// return visit sends a fresh code and verifies it, same two-step shape as
/// [EmailSignupStep], via `startEmailLoginOtp`/`loginWithEmail`.
class EmailLoginPage extends ConsumerStatefulWidget {
  const EmailLoginPage({super.key});

  @override
  ConsumerState<EmailLoginPage> createState() => _EmailLoginPageState();
}

class _EmailLoginPageState extends ConsumerState<EmailLoginPage> {
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

  // Optimistic transition, same as EmailSignupStep._showOtp — flips to the
  // OTP entry screen immediately, before the network call even starts.
  void _showOtp() {
    if (!_emailLooksValid) return;
    setState(() => _step = _Step.otp);
  }

  Future<int> _startLoginOtp() => ref
      .read(authSessionProvider.notifier)
      .startEmailLoginOtp(_emailController.text.trim());

  // No local try/catch — a failure (unknown email or wrong/expired code,
  // deliberately indistinguishable per CompleteEmailLogin's account-
  // enumeration-safe design) propagates to OtpEntry's own error handling,
  // which shows it inline — same convention as EmailSignupStep._onOtpEntered.
  Future<void> _onOtpEntered(String code) async {
    await ref
        .read(authSessionProvider.notifier)
        .loginWithEmail(email: _emailController.text.trim(), code: code);
    if (!mounted) return;
    // Same pushAndRemoveUntil reasoning as OnboardingFlow's own
    // post-sign-in navigation — this page was pushed on top of
    // LandingPage, so a plain pushReplacement would leave LandingPage
    // stranded under AppShell in the stack.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const AppShell()),
      (route) => false,
    );
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
      appBar: AppBar(title: const Text('SIGN IN')),
      body: AppBackground(
        imageOpacity: 0.35,
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
          'Welcome back',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: AppPalette.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Enter the email you signed up with — we’ll send you a code, no '
          'password needed. Used LinkedIn, Apple, or Google instead? Use '
          'that same button on the sign-up screen, it signs you in too.',
          style: TextStyle(
            fontSize: 12,
            color: AppPalette.textSecondary,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 24),
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
        OtpEntry(onSend: _startLoginOtp, onSubmit: _onOtpEntered),
      ],
    );
  }
}
