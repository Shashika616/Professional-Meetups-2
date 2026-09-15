import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/brand_marks.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';

/// The one-tap sign-in pair, platform-appropriate: Apple + LinkedIn on iOS,
/// Google + LinkedIn elsewhere. One widget, used by both the sign-up flow
/// and the sign-in page, because the buttons, the busy handling and the
/// error toasts are identical — only what happens after success differs,
/// and that is the caller's [onSignedIn].
///
/// Every provider call is resolve-or-create on the server: an identity
/// that already exists signs in, a new one signs up. [onSignedIn] is told
/// which happened via the session's `isNewUser`, so the sign-in page can
/// send an existing member straight in while a first-timer still gets
/// profile setup.
///
/// [ageConfirmedOver18] is the real, user-given attestation from whichever
/// screen hosts this widget: sign-up's full-screen AgeConfirmationStep, or
/// sign-in's inline checkbox. It is sent to the server verbatim and the
/// server records it as a legal self-attestation at account creation, so a
/// caller must never pass a constant `true` it did not obtain from the
/// user. While it is false the buttons are disabled AND [_run] refuses,
/// so no provider call can carry an attestation nobody made.
class SocialSignInSection extends ConsumerStatefulWidget {
  const SocialSignInSection({
    super.key,
    required this.onSignedIn,
    required this.ageConfirmedOver18,
    this.onBusyChanged,
  });

  /// Called after a successful sign-in. `isNewUser` is true when the
  /// provider identity had never been seen before.
  final Future<void> Function(bool isNewUser) onSignedIn;

  /// The user's own 18+ confirmation from the hosting screen. See the
  /// class comment.
  final bool ageConfirmedOver18;

  /// Lets a parent disable its own controls while a provider flow is open.
  final ValueChanged<bool>? onBusyChanged;

  @override
  ConsumerState<SocialSignInSection> createState() =>
      _SocialSignInSectionState();
}

class _SocialSignInSectionState extends ConsumerState<SocialSignInSection> {
  bool _busy = false;

  void _setBusy(bool value) {
    if (!mounted) return;
    setState(() => _busy = value);
    widget.onBusyChanged?.call(value);
  }

  Future<void> _run(String source, Future<void> Function() signIn) async {
    if (_busy) return; // a slow tap must not double-fire a provider flow
    // Belt and braces with the disabled buttons below: a provider call
    // never leaves this widget without the user's confirmation.
    if (!widget.ageConfirmedOver18) return;
    _setBusy(true);
    try {
      await signIn();
      if (!mounted) return;
      final isNewUser =
          ref.read(authSessionProvider).value?.session?.isNewUser ?? false;
      await widget.onSignedIn(isNewUser);
    } catch (error) {
      _handleError(source, error);
    } finally {
      _setBusy(false);
    }
  }

  /// TYPE PLUS A SANITIZED MESSAGE, never the raw error object: debugPrint
  /// survives release builds, and an untyped failure here is a raw
  /// PlatformException from a sign-in plugin, whose toString() can carry
  /// endpoint URLs or account identifiers. A cancellation (the user backed
  /// out of the provider's picker) gets a soft toast, not the red one.
  void _handleError(String source, Object error) {
    final safeMessage = error is AuthException ? error.message : '';
    debugPrint('$source failed: ${error.runtimeType} $safeMessage');
    if (!mounted) return;
    showSnack(
      context,
      error is AuthException
          ? error.message
          : 'Something went wrong. Please try again.',
      type: error is SignInCancelledException
          ? ToastType.info
          : ToastType.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    // defaultTargetPlatform, not dart:io Platform, so this stays testable
    // under `flutter test`. Apple has no native Android SDK and Google has
    // no first-class iOS placement requirement the way Apple does on iOS.
    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
    final notifier = ref.read(authSessionProvider.notifier);

    // NEUTRAL SURFACE, COLOURED MARK: both brand programmes expect the
    // provider's own logo on a plain light or dark button. The pair stays
    // visually co-equal by construction — same widget, same height.
    Widget provider({
      Key? key,
      required String label,
      required Widget mark,
      required VoidCallback onPressed,
    }) {
      return PrimaryButton(
        key: key,
        label: label,
        iconWidget: mark,
        fillColor: AppPalette.card,
        foregroundColor: AppPalette.textPrimary,
        borderColor: AppPalette.hairline,
        isLoading: _busy,
        // Disabled, not hidden, until the attestation is given: the user
        // sees what confirming unlocks.
        onPressed: widget.ageConfirmedOver18 ? onPressed : null,
      );
    }

    final ageConfirmed = widget.ageConfirmedOver18;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isIOS)
          provider(
            key: const Key('continueWithApple'),
            label: 'CONTINUE WITH APPLE',
            mark: AppleMark(size: 20, color: AppPalette.textPrimary),
            onPressed: () => _run(
              'signInWithApple',
              () => notifier.signInWithApple(ageConfirmedOver18: ageConfirmed),
            ),
          )
        else
          provider(
            key: const Key('continueWithGoogle'),
            label: 'CONTINUE WITH GOOGLE',
            mark: const GoogleMark(size: 20),
            onPressed: () => _run(
              'signInWithGoogle',
              () => notifier.signInWithGoogle(ageConfirmedOver18: ageConfirmed),
            ),
          ),
        const SizedBox(height: 12),
        provider(
          key: const Key('continueWithLinkedIn'),
          label: 'CONTINUE WITH LINKEDIN',
          mark: const LinkedInMark(size: 20),
          onPressed: () => _run(
            'signInWithLinkedIn',
            () => notifier.signInWithLinkedIn(ageConfirmedOver18: ageConfirmed),
          ),
        ),
      ],
    );
  }
}

/// A hairline with "or" set into it, separating the one-tap sign-in buttons
/// from the other ways in — shared by the sign-up and sign-in screens so the
/// two read as the same design.
class OrDivider extends StatelessWidget {
  const OrDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final line = Expanded(
      child: Divider(color: AppPalette.hairline, height: 1),
    );
    return Row(
      children: [
        line,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'or',
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
          ),
        ),
        line,
      ],
    );
  }
}
