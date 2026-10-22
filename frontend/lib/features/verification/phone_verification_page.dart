import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/validation/validators.dart';
import 'package:professional_connections_platform/core/models/country.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/verification/widgets/otp_entry.dart';
import 'package:professional_connections_platform/features/verification/widgets/phone_number_field.dart';
import 'package:professional_connections_platform/features/verification/widgets/verification_scaffold.dart';

/// Phone number entry → shared OTP widget. Reachable both from the
/// post-LinkedIn onboarding sequence and, independently, from
/// `ProfilePage` for a user who skipped and wants to finish later — same
/// screen either way (`frontend/PLAN.md`'s Level 2/3 addendum, Step 6).
///
/// # THE COUNTRY CODE IS A PICKER NOW
///
/// It used to be a hard-coded `+94` drawn into the placeholder, on the
/// reasoning that the launch market is Sri Lanka only. The number stayed
/// unverifiable for anyone outside it — a Sri Lankan member living abroad,
/// a visiting professional — and worse, a `+94` printed in the hint looked
/// like a control that simply did not respond. [PhoneNumberField] opens a
/// searchable country sheet ([kCountries]); Sri Lanka is still the default,
/// so the common case is still: open, type, send.
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
  final _numberController = TextEditingController();
  Country _country = kDefaultCountry;
  bool _showOtpEntry = false;

  /// Only after a failed send — see [PhoneNumberField.errorText].
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    // An already-verified number being edited comes back as E.164, so the
    // picker opens on ITS country rather than on the default — editing a
    // +971 number used to silently re-prefix it with +94.
    final split = splitPhoneNumber(widget.currentValue);
    if (widget.currentValue != null) {
      _country = split.country;
      _numberController.text = split.localNumber;
    }
    // Listening on the controller directly is what makes Send code react
    // as the user types.
    _numberController.addListener(_onFieldChanged);
  }

  void _onFieldChanged() => setState(() {});

  @override
  void dispose() {
    _numberController.removeListener(_onFieldChanged);
    _numberController.dispose();
    super.dispose();
  }

  /// E.164: the dial code, then the local part with the separators people
  /// type stripped out. `+94 77 123 4567` and `+94771234567` must reach
  /// the backend as the same string, or a resend looks like a new number.
  String get _fullNumber =>
      '${_country.dialCode}'
      '${_numberController.text.replaceAll(RegExp(r'[^0-9]'), '')}';

  // Optimistic transition (UX improvement) — flips to the OTP entry screen
  // immediately, instead of waiting on the network call first; OtpEntry
  // sends the code itself once mounted, via [_startVerification], and
  // shows its own optimistic countdown/loading/error state for that — see
  // OtpEntry's own doc comment for why a slow or failing backend no longer
  // stalls this screen.
  void _showOtp() {
    if (_showOtpEntry) return;
    if (Validators.phone(_fullNumber) != null) {
      setState(() => _submitted = true);
      return;
    }
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
      icon: AppIcons.phone,
      headline: 'Verify your phone',
      onSkip: () => Navigator.pop(context),
      child: !_showOtpEntry
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PhoneNumberField(
                  controller: _numberController,
                  country: _country,
                  onCountryChanged: (c) => setState(() => _country = c),
                  onSubmitted: _showOtp,
                  errorText: _submitted ? Validators.phone(_fullNumber) : null,
                ),
                const SizedBox(height: 16),
                PrimaryButton(
                  label: 'Send code',
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
