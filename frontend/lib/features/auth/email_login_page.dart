import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/app_shell.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/cafe_scene.dart';
import 'package:professional_connections_platform/core/widgets/glass_text_field.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/features/auth/social_sign_in_section.dart';
import 'package:professional_connections_platform/features/onboarding/age_confirmation_checkbox.dart';
import 'package:professional_connections_platform/features/onboarding/profile_setup_screen.dart';
import 'package:professional_connections_platform/features/verification/widgets/otp_entry.dart';

enum _Step { method, email, otp }

/// Sign-in for a returning user, reached from [LandingPage]'s "Sign in"
/// link — distinct from [OnboardingFlow]'s entry screen, which is for new
/// sign-ups. Offers the same one-tap providers as sign-up (they are
/// resolve-or-create on the server, so the same button signs an existing
/// member in) plus email-OTP (ADR-019 §1), the one path that genuinely
/// can't collapse into a single tap. No password anywhere, ever: every
/// return visit sends a fresh code and verifies it, same two-step shape as
/// [EmailSignupStep], via `startEmailLoginOtp`/`loginWithEmail`.
///
/// A provider tap by someone who has never signed up still creates an
/// account (that is what resolve-or-create means); the session's
/// `isNewUser` tells the two apart, and only a genuinely new account is
/// walked through profile setup. An existing member goes straight in.
class EmailLoginPage extends ConsumerStatefulWidget {
  const EmailLoginPage({super.key});

  @override
  ConsumerState<EmailLoginPage> createState() => _EmailLoginPageState();
}

class _EmailLoginPageState extends ConsumerState<EmailLoginPage> {
  _Step _step = _Step.method;
  bool _socialBusy = false;

  /// The 18+ attestation for THIS screen. A provider tap here is
  /// resolve-or-create, so a first-timer who comes in through "Sign in"
  /// gets an account created with whatever value is sent; it must be one
  /// they gave (Plan 18, Fix 2). Off until the box is checked, and EVERY
  /// way in on this screen stays disabled until then, email included.
  /// Email OTP login cannot create an account, so it does not strictly
  /// need the attestation, but one gate over all three buttons is what a
  /// person expects the box to mean; a screen where two doors are locked
  /// and the third is open reads as a bug.
  bool _ageConfirmed = false;
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
    _navigateToAppShell();
  }

  /// Provider sign-in landed. A returning member goes straight in; a
  /// first-timer who happened to start from this page rather than sign-up
  /// still gets the mandatory profile-setup screen, the same one
  /// OnboardingFlow shows, so no account skips it by choosing the other
  /// door.
  Future<void> _onSocialSignedIn(bool isNewUser) async {
    if (isNewUser) {
      final fullName =
          ref.read(authSessionProvider).value?.session?.fullName ?? '';
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ProfileSetupScreen(initialFullName: fullName),
        ),
      );
      if (!mounted) return;
    }
    _navigateToAppShell();
  }

  // Same pushAndRemoveUntil reasoning as OnboardingFlow's own post-sign-in
  // navigation — this page was pushed on top of LandingPage, so a plain
  // pushReplacement would leave LandingPage stranded under AppShell in the
  // stack.
  void _navigateToAppShell() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const AppShell()),
      (route) => false,
    );
  }

  void _backToMethods() {
    if (_socialBusy) return;
    setState(() => _step = _Step.method);
  }

  @override
  Widget build(BuildContext context) {
    // The system back gesture and the app bar arrow must agree: on the
    // email step both return to the method choice, not to LandingPage.
    return PopScope(
      canPop: _step != _Step.email,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _backToMethods();
      },
      child: _scaffold(context),
    );
  }

  Widget _scaffold(BuildContext context) {
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
      appBar: AppBar(
        title: const Text('SIGN IN'),
        // The email step is a page within the page: back returns to the
        // method choice rather than leaving sign-in altogether. The first
        // and last steps keep the default back (pop to LandingPage).
        leading: _step == _Step.email
            ? BackButton(onPressed: _backToMethods)
            : null,
      ),
      body: AppBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: switch (_step) {
              _Step.method => _methodStep(),
              _Step.email => _emailStep(),
              _Step.otp => _otpStep(),
            },
          ),
        ),
      ),
    );
  }

  Widget _methodStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(
          'Welcome back',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: AppPalette.textPrimary,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 18),
        // The same illustration, sized the same way, as the sign-up
        // screen's hero, so the two doors into the app read as one design.
        Builder(
          builder: (context) {
            final h = MediaQuery.sizeOf(context).height;
            return CafeScene(height: (h * 0.26).clamp(150.0, 260.0));
          },
        ),
        const SizedBox(height: 22),
        // Same control and sentence as sign-up's age step. A returning
        // member pays one extra tap the first time; a new account created
        // through this door gets a real attestation instead of a constant.
        AgeConfirmationCheckbox(
          value: _ageConfirmed,
          onChanged: _socialBusy
              ? (_) {}
              : (v) => setState(() => _ageConfirmed = v),
        ),
        const SizedBox(height: 14),
        SocialSignInSection(
          onSignedIn: _onSocialSignedIn,
          ageConfirmedOver18: _ageConfirmed,
          onBusyChanged: (busy) => setState(() => _socialBusy = busy),
        ),
        const SizedBox(height: 18),
        const OrDivider(),
        const SizedBox(height: 14),
        SecondaryButton(
          key: const Key('continueWithEmail'),
          label: 'CONTINUE WITH EMAIL',
          icon: Icons.mail_outline_rounded,
          height: 52,
          color: AppPalette.candyBlue,
          borderColor: AppPalette.candyBlue.withValues(alpha: 0.55),
          onPressed: _socialBusy || !_ageConfirmed
              ? null
              : () => setState(() => _step = _Step.email),
        ),
      ],
    );
  }

  Widget _emailStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(
          'Sign in with email',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: AppPalette.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'We will send a one-time code to the email you signed up with.',
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
