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
import 'package:professional_connections_platform/core/widgets/signing_in_overlay.dart'
    show SigningInOverlay;

/// The one-tap sign-in buttons, platform-appropriate: Apple + Google +
/// LinkedIn on iOS, Google + LinkedIn elsewhere. One widget, used by both
/// the sign-up flow and the sign-in page, because the buttons, the busy
/// handling and the error toasts are identical — only what happens after
/// success differs, and that is the caller's [onSignedIn].
///
/// Every button is the same [PrimaryButton] treatment at the same height:
/// App Store Guideline 4.8 requires Sign in with Apple to be no less
/// prominent than any other sign-in option, and `onboarding_flow_test`
/// asserts the sizes are equal. What separates the group is spacing, not
/// a different button: Apple and Google are generic identity providers
/// and sit 12 apart; LinkedIn is this app's professional-identity anchor,
/// a different kind of thing, and sits 20 below them (Plan 21).
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
    this.pageShowsOverlay = false,
  });

  /// Called after a successful sign-in. `isNewUser` is true when the
  /// provider identity had never been seen before.
  final Future<void> Function(bool isNewUser) onSignedIn;

  /// The user's own 18+ confirmation from the hosting screen. See the
  /// class comment.
  final bool ageConfirmedOver18;

  /// Lets a parent disable its own controls while a provider flow is open.
  final ValueChanged<bool>? onBusyChanged;

  /// True when the hosting page raises a [SigningInOverlay] from
  /// [onBusyChanged]. Then the overlay's ring is THE loading indicator and
  /// the tapped button does not spin as well: two indicators for one wait
  /// is what the overlay exists to prevent (gap #49). False keeps the
  /// per-button spinner for a host that shows nothing page-level.
  final bool pageShowsOverlay;

  @override
  ConsumerState<SocialSignInSection> createState() =>
      _SocialSignInSectionState();
}

class _SocialSignInSectionState extends ConsumerState<SocialSignInSection> {
  /// Which provider is running, or null. A name rather than a bool so
  /// only the tapped button shows its spinner: with one shared flag both
  /// buttons spun and a tap on Google made LinkedIn look busy too.
  String? _busySource;

  bool get _busy => _busySource != null;

  void _setBusy(String? source) {
    if (!mounted) return;
    setState(() => _busySource = source);
    widget.onBusyChanged?.call(source != null);
  }

  Future<void> _run(String source, Future<void> Function() signIn) async {
    if (_busy) return; // a slow tap must not double-fire a provider flow
    // Belt and braces with the disabled buttons below: a provider call
    // never leaves this widget without the user's confirmation.
    if (!widget.ageConfirmedOver18) return;
    _setBusy(source);
    try {
      await signIn();
      if (!mounted) return;
      final isNewUser =
          ref.read(authSessionProvider).value?.session?.isNewUser ?? false;
      await widget.onSignedIn(isNewUser);
    } catch (error) {
      _handleError(source, error);
    } finally {
      _setBusy(null);
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
    // under `flutter test`. Only Apple is platform-specific, and only by
    // Apple's own rules: there is no native Sign in with Apple SDK on
    // Android, and on iOS the App Store requires it beside any other
    // one-tap option. Google is offered on both platforms because nothing
    // platform-side prevents it: `signInWithGoogle` has no platform check
    // and posts to the same federated endpoint from either OS.
    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
    final notifier = ref.read(authSessionProvider.notifier);

    // NEUTRAL SURFACE, COLOURED MARK: both brand programmes expect the
    // provider's own logo on a plain light or dark button. The pair stays
    // visually co-equal by construction — same widget, same height.
    Widget provider({
      Key? key,
      required String source,
      required String label,
      required Widget mark,
      required VoidCallback onPressed,
    }) {
      // Disabled, not hidden, until the attestation is given: the user
      // sees what confirming unlocks. Dimmed as a whole, mark and label
      // included: PrimaryButton's own disabled state only fades the fill,
      // which on the neutral card surface is invisible in dark mode. The
      // provider that is NOT running dims the same way while the other
      // one is, so exactly one button ever looks busy, and none does when
      // the page's overlay is carrying the loading state instead.
      final isRunning = _busySource == source;
      final spins = isRunning && !widget.pageShowsOverlay;
      final dimmed = !widget.ageConfirmedOver18 || (_busy && !isRunning);
      return Opacity(
        opacity: dimmed ? 0.45 : 1,
        child: PrimaryButton(
          key: key,
          label: label,
          iconWidget: mark,
          fillColor: AppPalette.card,
          foregroundColor: AppPalette.textPrimary,
          borderColor: AppPalette.hairline,
          isLoading: spins,
          onPressed: widget.ageConfirmedOver18 && !_busy ? onPressed : null,
        ),
      );
    }

    final ageConfirmed = widget.ageConfirmedOver18;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isIOS) ...[
          provider(
            key: const Key('continueWithApple'),
            source: 'signInWithApple',
            label: 'CONTINUE WITH APPLE',
            mark: AppleMark(size: 20, color: AppPalette.textPrimary),
            onPressed: () => _run(
              'signInWithApple',
              () => notifier.signInWithApple(ageConfirmedOver18: ageConfirmed),
            ),
          ),
          const SizedBox(height: 12),
        ],
        provider(
          key: const Key('continueWithGoogle'),
          source: 'signInWithGoogle',
          label: 'CONTINUE WITH GOOGLE',
          mark: const GoogleMark(size: 20),
          onPressed: () => _run(
            'signInWithGoogle',
            () => notifier.signInWithGoogle(ageConfirmedOver18: ageConfirmed),
          ),
        ),
        // Wider than the 12 above on purpose: the identity providers are a
        // pair, LinkedIn is the professional anchor. See the class comment.
        const SizedBox(height: 20),
        provider(
          key: const Key('continueWithLinkedIn'),
          source: 'signInWithLinkedIn',
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
