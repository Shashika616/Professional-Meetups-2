import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/validation/validators.dart';
import 'package:professional_connections_platform/core/widgets/glass_text_field.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/verification/widgets/otp_entry.dart';
import 'package:professional_connections_platform/features/verification/widgets/verification_scaffold.dart';

/// Same shape as [PersonalEmailVerificationPage], against the
/// corporate-email endpoints. Reachable both from the post-LinkedIn
/// onboarding sequence and independently from `ProfilePage`
/// (`frontend/PLAN.md`'s Level 2/3 addendum, Step 6).
///
/// [currentDomainHint] (ADR-023 §5) is the already-verified
/// `company_domain` — passed when this screen is opened to *change* an
/// already-verified work email (`ProfilePage`), null/empty for a genuine
/// first-time verification. There is no raw work email to pre-fill (ADR-003
/// — it was never stored past the original verification), so the
/// company-name field is pre-filled with a best-effort guess: the domain
/// itself, since no known-company display-name-by-domain lookup is exposed
/// to any client today (only name-to-domain, the reverse direction, and
/// only inside the auth service's own verification RPC). The screen always
/// ends in a fresh OTP round-trip against whatever new email is entered.
class CorporateEmailVerificationPage extends ConsumerStatefulWidget {
  const CorporateEmailVerificationPage({super.key, this.currentDomainHint});

  final String? currentDomainHint;

  @override
  ConsumerState<CorporateEmailVerificationPage> createState() =>
      _CorporateEmailVerificationPageState();
}

class _CorporateEmailVerificationPageState
    extends ConsumerState<CorporateEmailVerificationPage> {
  final _emailController = TextEditingController();
  final _companyNameController = TextEditingController();
  bool _showOtpEntry = false;

  bool get _isChangingExisting => (widget.currentDomainHint ?? '').isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_isChangingExisting) {
      _companyNameController.text = widget.currentDomainHint!;
    }
    _emailController.addListener(_onFieldChanged);
    _companyNameController.addListener(_onFieldChanged);
  }

  void _onFieldChanged() => setState(() {});

  @override
  void dispose() {
    _emailController.removeListener(_onFieldChanged);
    _companyNameController.removeListener(_onFieldChanged);
    _emailController.dispose();
    _companyNameController.dispose();
    super.dispose();
  }

  String get _email => _emailController.text.trim();
  String get _companyName => _companyNameController.text.trim();

  /// Client-side hint only — mirrors the backend's free-domain list
  /// (Verification Model § 5) but never blocks submission; the backend
  /// remains the actual enforcement point. A server-side rejection
  /// (`WorkEmailDomainRejectedException`) still surfaces clearly — inline
  /// on the OTP screen via [OtpEntry]'s own error handling, since sending
  /// is now optimistic (see [_showOtp]) rather than gated on this call
  /// succeeding first. Domain list consolidated into [Validators
  /// .freeProviders] (2026-08-31 review hardening) rather than kept as a
  /// second, separately-maintained copy here.
  bool get _looksLikeFreeEmail {
    final parts = _email.split('@');
    if (parts.length != 2) return false;
    return Validators.freeProviders.contains(parts[1].toLowerCase());
  }

  // Optimistic transition (UX improvement) — flips to the OTP entry screen
  // immediately, instead of waiting on the network call first; OtpEntry
  // sends the code itself once mounted, via [_startVerification], and
  // shows its own optimistic countdown/loading/error state for that — see
  // OtpEntry's own doc comment for why a slow or failing backend no longer
  // stalls this screen. Gated on plain email shape only ([Validators
  // .email]), not [Validators.corporateEmail]'s free-domain/role-based
  // rejection — a free-domain address must still reach the backend so its
  // specific [WorkEmailDomainRejectedException] message can surface,
  // rather than being silently blocked here.
  void _showOtp() {
    if (_showOtpEntry ||
        Validators.email(_email) != null ||
        _companyName.isEmpty) {
      return;
    }
    setState(() => _showOtpEntry = true);
  }

  Future<int> _startVerification() async {
    try {
      return await ref
          .read(authServiceProvider)
          .startCorporateEmailVerification(_email);
    } on SessionExpiredException {
      // No local error shown here — AppShell's listener navigates to
      // LandingPage and shows the "session expired" message itself;
      // rethrown so OtpEntry's own catch doesn't also surface a redundant
      // generic message.
      if (mounted) ref.read(authSessionProvider.notifier).forceSignOut();
      rethrow;
    }
    // Includes WorkEmailDomainRejectedException on a genuine rejection —
    // its .message is already the backend's specific rejection text,
    // shown verbatim by OtpEntry's error handling (self-review checklist).
  }

  Future<void> _verify(String code) async {
    try {
      final session = await ref
          .read(authServiceProvider)
          .verifyCorporateEmailCode(_email, code, _companyName);
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
      icon: Icons.work_outline_rounded,
      headline: _isChangingExisting
          ? 'Change Work Email'
          : 'Verify Your Work Email',
      trustBenefit:
          'Verifying a work email is the strongest trust signal short of '
          'KYC — it unlocks a verified badge other members can see.',
      onSkip: () => Navigator.pop(context),
      child: !_showOtpEntry
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_isChangingExisting) ...[
                  Text(
                    'Currently verified: ${widget.currentDomainHint}',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppPalette.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                GlassTextField(
                  controller: _companyNameController,
                  icon: Icons.apartment_outlined,
                  hint: 'Company or organization name',
                ),
                const SizedBox(height: 12),
                GlassTextField(
                  controller: _emailController,
                  icon: Icons.work_outline_rounded,
                  hint: 'firstname.lastname@company.com',
                  keyboardType: TextInputType.emailAddress,
                  validator: (_) => Validators.email(_email),
                ),
                if (_looksLikeFreeEmail) ...[
                  const SizedBox(height: 8),
                  Text(
                    'This looks like a personal email address — work '
                    'email verification needs your company address.',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ],
                // ADR-019 §3's required copy — (a) directly under the
                // field, we never store the raw address; (b) near the
                // send/verify action, the reuse-abuse warning.
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
                const SizedBox(height: 16),
                PrimaryButton(
                  label: 'SEND CODE',
                  onPressed:
                      Validators.email(_email) == null &&
                          _companyName.isNotEmpty
                      ? _showOtp
                      : null,
                ),
              ],
            )
          : OtpEntry(onSend: _startVerification, onSubmit: _verify),
    );
  }
}
