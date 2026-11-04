part of 'profile_page.dart';

/// Profile's "Connect LinkedIn" entry point (ADR-014 Step 7) — calls
/// [AuthSessionNotifier.linkLinkedIn], not `signInWithLinkedIn` (that
/// creates/resolves an account; this links to the caller's already-
/// authenticated one).
///
/// This widget owns the button, the busy state and the failure toast, and
/// nothing else. What follows a SUCCESS — the suggested-name offer and the
/// pending-verification sequence a fresh LinkedIn signup would have shown —
/// is handed to [onLinked], because success is exactly what takes this
/// widget off the screen.
class ConnectLinkedInBanner extends ConsumerStatefulWidget {
  const ConnectLinkedInBanner({super.key, this.onLinked});

  /// Run once the link succeeds, with the server's suggested name (`''`
  /// when there is nothing to suggest). Owned by the page rather than this
  /// widget on purpose: a successful link removes this banner from the
  /// tree, so work awaited here would be abandoned half-done.
  final Future<void> Function(String suggestedName)? onLinked;

  @override
  ConsumerState<ConnectLinkedInBanner> createState() =>
      ConnectLinkedInBannerState();
}

class ConnectLinkedInBannerState extends ConsumerState<ConnectLinkedInBanner> {
  bool _busy = false;

  Future<void> _connect() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final suggestedName = await ref
          .read(authSessionProvider.notifier)
          .linkLinkedIn();
      // No `mounted` check before this call, deliberately: by now this
      // banner may already be gone (the profile it is conditioned on just
      // changed), and the callback belongs to the page, which is not.
      await widget.onLinked?.call(suggestedName);
    } catch (error) {
      if (mounted) {
        // A cancellation (closed the browser without finishing) gets a
        // softer, non-alarming toast, not the red error styling a genuine
        // network/server failure gets — same distinction
        // onboarding_flow.dart's sign-in error handling makes.
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
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // # WHY THIS IS ONE TAPPABLE BANNER AND NOT A CARD WITH A BUTTON
    //
    // It used to be a bordered card containing a heading that read
    // "Connect LinkedIn", a paragraph, and a button that ALSO read
    // "Connect LinkedIn" — the same three words twice, 90px apart, as the
    // two loudest things in the card. (The 2026-10 copy pass is what made
    // that undeniable: before it, the heading was uppercase and the button
    // was not, which disguised the repetition as hierarchy.)
    //
    // The screen set makes this a banner: title, one line of why, and the
    // whole surface is the target. There is now exactly one "Connect
    // LinkedIn" on the screen, and it is the thing you press.
    return Semantics(
      button: true,
      enabled: !_busy,
      child: GestureDetector(
        onTap: _busy ? null : _connect,
        behavior: HitTestBehavior.opaque,
        child: AppBanner(
          icon: AppIcons.work,
          tone: AppTone.accent,
          title: 'Connect LinkedIn',
          message: 'Your account is view only until you connect it.',
          trailing: _busy
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppPalette.candyBlue,
                  ),
                )
              : AppIcon(
                  AppIcons.forward,
                  size: 20,
                  color: AppPalette.candyBlue,
                ),
        ),
      ),
    );
  }
}
