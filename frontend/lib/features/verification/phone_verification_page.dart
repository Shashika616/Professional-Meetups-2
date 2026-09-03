import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/validation/validators.dart';
import 'package:professional_connections_platform/core/widgets/glass_text_field.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/verification/widgets/otp_entry.dart';
import 'package:professional_connections_platform/features/verification/widgets/verification_scaffold.dart';

/// Phone number entry → shared OTP widget. Reachable both from the
/// post-LinkedIn onboarding sequence and, independently, from
/// `ProfilePage` for a user who skipped and wants to finish later — same
/// screen either way (`frontend/PLAN.md`'s Level 2/3 addendum, Step 6).
///
/// No country-code picker UI: the launch market is Sri Lanka only (see
/// `docs/00-project/vision.md`), so the `+94` prefix is simply fixed —
/// building a full multi-country picker isn't justified by a single-market
/// launch scope. The user types only their local number.
///
/// [currentValue] (ADR-023 §5) is the real, already-verified number —
/// passed when this screen is opened to *edit* an already-verified row
/// (`ProfilePage`), null for a genuine first-time verification. Shown
/// pre-filled and fully editable; it is never resubmitted as-is — SEND CODE
/// always runs a fresh OTP round-trip against whatever value is in the
/// field when tapped, identical to first-time verification.
class PhoneVerificationPage extends ConsumerStatefulWidget {
  const PhoneVerificationPage({super.key, this.currentValue});

  final String? currentValue;

  @override
  ConsumerState<PhoneVerificationPage> createState() =>
      _PhoneVerificationPageState();
}

class _PhoneVerificationPageState extends ConsumerState<PhoneVerificationPage> {
  static const _countryCode = '+94';

  final _numberController = TextEditingController();
  bool _showOtpEntry = false;

  @override
  void initState() {
    super.initState();
    final current = widget.currentValue;
    if (current != null && current.startsWith(_countryCode)) {
      _numberController.text = current.substring(_countryCode.length);
    }
    // GlassTextField doesn't expose onChanged — listening on the
    // controller directly is what makes SEND CODE react as the user types.
    _numberController.addListener(_onFieldChanged);
  }

  void _onFieldChanged() => setState(() {});

  @override
  void dispose() {
    _numberController.removeListener(_onFieldChanged);
    _numberController.dispose();
    super.dispose();
  }

  String get _fullNumber => '$_countryCode${_numberController.text.trim()}';

  // Optimistic transition (UX improvement) — flips to the OTP entry screen
  // immediately, instead of waiting on the network call first; OtpEntry
  // sends the code itself once mounted, via [_startVerification], and
  // shows its own optimistic countdown/loading/error state for that — see
  // OtpEntry's own doc comment for why a slow or failing backend no longer
  // stalls this screen.
  void _showOtp() {
    if (_showOtpEntry || Validators.phone(_fullNumber) != null) return;
    setState(() => _showOtpEntry = true);
  }

  Future<int> _startVerification() async {
    try {
      return await ref
          .read(authServiceProvider)
          .startPhoneVerification(_fullNumber);
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
          .verifyPhoneCode(_fullNumber, code);
      await ref
          .read(authSessionProvider.notifier)
          .completeVerification(session);
      if (!mounted) return;
      Navigator.pop(context);
    } on SessionExpiredException {
      // Rethrown so OtpEntry's own catch still surfaces the (specific,
      // non-generic) message while AppShell's listener navigates away —
      // forceSignOut() is what actually matters here, not suppressing the
      // message OtpEntry would otherwise show.
      if (mounted) ref.read(authSessionProvider.notifier).forceSignOut();
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return VerificationScaffold(
      icon: Icons.phone_iphone_rounded,
      headline: 'Verify Your Phone',
      trustBenefit:
          'Verifying your number unlocks messaging other members and '
          'helps keep the community scam-resistant.',
      onSkip: () => Navigator.pop(context),
      child: !_showOtpEntry
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GlassTextField(
                  controller: _numberController,
                  icon: Icons.phone_iphone_rounded,
                  hint: '$_countryCode 7X XXX XXXX',
                  keyboardType: TextInputType.phone,
                  validator: (_) => Validators.phone(_fullNumber),
                ),
                const SizedBox(height: 16),
                PrimaryButton(
                  label: 'SEND CODE',
                  onPressed: Validators.phone(_fullNumber) == null
                      ? _showOtp
                      : null,
                ),
              ],
            )
          : OtpEntry(onSend: _startVerification, onSubmit: _verify),
    );
  }
}
