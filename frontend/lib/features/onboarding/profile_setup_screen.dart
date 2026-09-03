import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/glass_text_field.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/features/verification/widgets/otp_entry.dart';

/// The new post-auth screen (ADR-019 §2) — shown once, right after any of
/// the four sign-up/login paths succeeds, before landing in the app shell
/// (`OnboardingFlow._goToAppShell`). It's the *only* screen initial
/// onboarding shows now — the Level 2/3 phone/personal-email/personal-
/// details/corporate-email sequence no longer runs there at all; those
/// stay reachable later from `ProfilePage`. Captures full name plus an
/// *optional* company/organization name + email pair; if the company
/// email is filled in, it must be OTP-verified (reusing
/// `StartCorporateEmailVerification`/`VerifyCorporateEmailCode`, the same
/// RPCs `CorporateEmailVerificationPage` uses) before this screen can be
/// dismissed with that field populated — leaving both company fields blank
/// is a valid way to finish the screen. The whole screen is also
/// skippable via its own "Skip for now" (same convention as every Level
/// 2/3 verification screen), which pops without saving anything at all,
/// not even the name.
///
/// Structured like `PersonalDetailsPage`/`AgeConfirmationStep` (a single
/// form, one backend call on submit) rather than `EmailSignupStep`'s
/// multi-step-enum shape — the company-email OTP sub-flow is an inline
/// optional detour, not a wizard step of its own.
class ProfileSetupScreen extends ConsumerStatefulWidget {
  const ProfileSetupScreen({super.key, required this.initialFullName});

  /// Pre-filled from whatever the just-completed auth call's response
  /// already carries as a name — Apple/Google/LinkedIn responses usually
  /// have one; email-OTP's never does, so this is often empty, and the
  /// field is editable either way.
  final String initialFullName;

  @override
  ConsumerState<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends ConsumerState<ProfileSetupScreen> {
  late final _fullNameController = TextEditingController(
    text: widget.initialFullName,
  );
  final _companyNameController = TextEditingController();
  final _companyEmailController = TextEditingController();

  bool _showOtpEntry = false;
  bool _companyEmailVerified = false;
  bool _submitting = false;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    _fullNameController.addListener(_onFieldChanged);
    _companyNameController.addListener(_onCompanyNameChanged);
    _companyEmailController.addListener(_onFieldChanged);
  }

  void _onFieldChanged() => setState(() {});

  // Clearing the company name after having entered a company email resets
  // the whole company sub-flow — the pairing is the point (ADR-019 §2), an
  // email with no name attached shouldn't linger in an enabled-but-orphaned
  // field.
  void _onCompanyNameChanged() {
    if (_companyNameController.text.trim().isEmpty) {
      setState(() {
        _companyEmailController.clear();
        _showOtpEntry = false;
        _companyEmailVerified = false;
      });
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _fullNameController.removeListener(_onFieldChanged);
    _companyNameController.removeListener(_onCompanyNameChanged);
    _companyEmailController.removeListener(_onFieldChanged);
    _fullNameController.dispose();
    _companyNameController.dispose();
    _companyEmailController.dispose();
    super.dispose();
  }

  String get _fullName => _fullNameController.text.trim();
  String get _companyName => _companyNameController.text.trim();
  String get _companyEmail => _companyEmailController.text.trim();

  bool get _canContinue => _fullName.isNotEmpty;

  void _startCompanyEmailVerification() {
    if (_showOtpEntry || _companyEmail.isEmpty) return;
    setState(() {
      _showOtpEntry = true;
      _validationError = null;
    });
  }

  Future<int> _sendCompanyEmailOtp() => ref
      .read(authServiceProvider)
      .startCorporateEmailVerification(_companyEmail);

  Future<void> _verifyCompanyEmailOtp(String code) async {
    final session = await ref
        .read(authServiceProvider)
        .verifyCorporateEmailCode(_companyEmail, code, _companyName);
    await ref.read(authSessionProvider.notifier).completeVerification(session);
    if (!mounted) return;
    setState(() {
      _companyEmailVerified = true;
      _showOtpEntry = false;
    });
  }

  // Skippable, same as every Level 2/3 verification screen (VerificationScaffold's
  // own "Skip for now") — pops without calling completeProfileSetup at all,
  // not even for the full name. This is a data-capture screen, not a trust
  // gate (ADR-019 §2); nothing here blocks reaching AppShell.
  void _skip() {
    if (_submitting) return;
    Navigator.pop(context);
  }

  Future<void> _onContinue() async {
    if (_submitting || !_canContinue) return;
    if (_companyEmail.isNotEmpty && !_companyEmailVerified) {
      setState(
        () => _validationError =
            'Please verify your company email, or clear it, to continue.',
      );
      return;
    }
    setState(() {
      _submitting = true;
      _validationError = null;
    });
    try {
      // Company fields are omitted here — if they were filled in, the
      // verify sub-flow above already persisted them server-side
      // (VerifyCorporateEmailCode); passing them again would just
      // re-trigger a fresh, unnecessary OTP send.
      await ref
          .read(authSessionProvider.notifier)
          .completeProfileSetup(fullName: _fullName);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _validationError = error is AuthException
            ? error.message
            : 'Something went wrong. Please try again.';
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
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
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        // FittedBox, not a bare Text — "COMPLETE YOUR PROFILE" at the
        // theme's letter-spaced title style doesn't fit next to the Skip
        // action on narrow devices; shrinking to fit keeps the full text
        // visible instead of the default ellipsis truncation.
        title: const FittedBox(
          fit: BoxFit.scaleDown,
          child: Text('COMPLETE YOUR PROFILE'),
        ),
        actions: [
          TextButton(
            onPressed: _skip,
            child: Text(
              'Skip for now',
              style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
            ),
          ),
        ],
      ),
      body: AppBackground(
        imageOpacity: 0.35,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                Text(
                  'Tell us about yourself',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: AppPalette.textPrimary,
                  ),
                ),
                const SizedBox(height: 20),
                GlassTextField(
                  controller: _fullNameController,
                  icon: Icons.badge_outlined,
                  hint: 'Full name',
                ),
                const SizedBox(height: 24),
                Text(
                  'COMPANY OR ORGANIZATION (OPTIONAL)',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 2.2,
                    fontWeight: FontWeight.w600,
                    color: AppPalette.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                GlassTextField(
                  controller: _companyNameController,
                  icon: Icons.apartment_outlined,
                  hint: 'Company or organization name',
                ),
                const SizedBox(height: 12),
                _companyEmailField(),
                const SizedBox(height: 8),
                Text(
                  'We don’t store this email — only that it proved you '
                  'have access to an inbox at this company’s domain.',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppPalette.textSecondary.withValues(alpha: 0.85),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Verifying the same company email on more than one '
                  'account harms that company’s standing on the platform.',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppPalette.textSecondary.withValues(alpha: 0.85),
                  ),
                ),
                if (_showOtpEntry) ...[
                  const SizedBox(height: 16),
                  OtpEntry(
                    onSend: _sendCompanyEmailOtp,
                    onSubmit: _verifyCompanyEmailOtp,
                  ),
                ],
                if (_validationError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _validationError!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppPalette.danger, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 24),
                PrimaryButton(
                  label: 'CONTINUE',
                  isLoading: _submitting,
                  onPressed: _canContinue ? _onContinue : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _companyEmailField() {
    if (_companyEmailVerified) {
      return Row(
        children: [
          Icon(
            Icons.check_circle_rounded,
            color: AppPalette.verified,
            size: 18,
          ),
          SizedBox(width: 8),
          Text(
            'Work email verified',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppPalette.verified,
            ),
          ),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: GlassTextField(
            controller: _companyEmailController,
            icon: Icons.work_outline_rounded,
            hint: 'firstname.lastname@company.com',
            keyboardType: TextInputType.emailAddress,
            enabled: _companyName.isNotEmpty && !_showOtpEntry,
          ),
        ),
        if (!_showOtpEntry) ...[
          const SizedBox(width: 8),
          SizedBox(
            width: 90,
            child: SecondaryButton(
              label: 'VERIFY',
              height: 48,
              onPressed: _companyEmail.isNotEmpty
                  ? _startCompanyEmailVerification
                  : null,
            ),
          ),
        ],
      ],
    );
  }
}
