import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/glass_text_field.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/verification/widgets/verification_scaffold.dart';

/// Legal name — the one Level 2 step with no OTP, since it's self-reported
/// (Verification Model § 4), not verified against anything. Reachable both
/// from the post-LinkedIn onboarding sequence and independently from
/// `ProfilePage` (`frontend/PLAN.md`'s Level 2/3 addendum, Step 6).
///
/// Address was removed from this screen entirely by ADR-023 §1 — it's no
/// longer part of the Level 2 bundle. The `address` field on
/// `AuthService.submitPersonalDetails` still exists (the backend still
/// accepts one if sent, ADR-023 §1); this screen just never populates it.
///
/// [profile] (ADR-023 §3/§5), when provided, drives the legal-name pre-fill
/// and lets this screen double as the "edit" entry point for an
/// already-submitted legal name: pre-fills from `profile.fullName` only when
/// `personalDetailsComplete` is false (a one-time starting suggestion, never
/// re-shown once a real legal name exists), otherwise from the actual
/// current `profile.legalName`.
class PersonalDetailsPage extends ConsumerStatefulWidget {
  const PersonalDetailsPage({super.key, this.profile});

  final UserProfile? profile;

  @override
  ConsumerState<PersonalDetailsPage> createState() =>
      _PersonalDetailsPageState();
}

class _PersonalDetailsPageState extends ConsumerState<PersonalDetailsPage> {
  final _legalNameController = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final profile = widget.profile;
    if (profile != null) {
      _legalNameController.text = profile.personalDetailsComplete
          ? profile.legalName
          : profile.fullName;
    }
    // GlassTextField doesn't expose onChanged — listening on the
    // controller directly is what makes CONTINUE react as the user types.
    _legalNameController.addListener(_onFieldChanged);
  }

  void _onFieldChanged() => setState(() {});

  @override
  void dispose() {
    _legalNameController.removeListener(_onFieldChanged);
    _legalNameController.dispose();
    super.dispose();
  }

  bool get _canSubmit => _legalNameController.text.trim().isNotEmpty;

  Future<void> _submit() async {
    if (_submitting || !_canSubmit) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final session = await ref
          .read(authServiceProvider)
          .submitPersonalDetails(_legalNameController.text.trim(), '');
      await ref
          .read(authSessionProvider.notifier)
          .completeVerification(session);
      if (!mounted) return;
      showSnack(context, 'Personal details saved.', type: ToastType.success);
      Navigator.pop(context);
    } on SessionExpiredException {
      // No local error shown — AppShell's listener navigates to LandingPage
      // and shows the "session expired" message itself.
      if (mounted) ref.read(authSessionProvider.notifier).forceSignOut();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is AuthException
            ? error.message
            : 'Something went wrong. Please try again.';
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return VerificationScaffold(
      icon: Icons.badge_outlined,
      headline: 'Personal Details',
      trustBenefit:
          'Your legal name is never shown to other members. It helps '
          'confirm you\'re a real professional and supports incident '
          'response if it\'s ever needed.',
      onSkip: () => Navigator.pop(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassTextField(
            controller: _legalNameController,
            icon: Icons.badge_outlined,
            hint: 'Legal name',
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppPalette.danger, fontSize: 12),
            ),
          ],
          const SizedBox(height: 16),
          PrimaryButton(
            label: 'CONTINUE',
            isLoading: _submitting,
            onPressed: _canSubmit ? _submit : null,
          ),
        ],
      ),
    );
  }
}
