part of 'profile_page.dart';

/// Offers LinkedIn's name after a Profile-initiated link when it differs
/// from the one on the account (Plan 22). Resolves to true on UPDATE, and
/// to null on KEEP MINE or a tap outside — only an explicit yes changes
/// anything, which is the whole point of asking.
///
/// Stateless and unbusy by design: the update it triggers runs on the page
/// behind it, reported by the same toast a manual name edit uses, so this
/// dialog closes the moment it is answered.
class _SuggestedNameDialog extends StatelessWidget {
  const _SuggestedNameDialog({required this.suggestedName});

  final String suggestedName;

  @override
  Widget build(BuildContext context) {
    return AppConfirmDialog(
      title: 'Update your name?',
      message:
          'LinkedIn shows your name as $suggestedName. '
          'Update your profile to match?',
      confirmLabel: 'Update',
      cancelLabel: 'Keep mine',
      onConfirm: () => Navigator.pop(context, true),
      onCancel: () => Navigator.pop(context),
    );
  }
}

/// The full-name edit dialog (ADR-023 §5), split out as its own
/// [StatefulWidget] so its [TextEditingController] is owned by — and
/// disposed by — the State's own lifecycle, the same pattern
/// `meetup_detail_page.dart`'s `_WithdrawNoteDialog` and
/// `host_meetup_controls.dart`'s `_CancelReasonDialog` already use. Resolves
/// to null on CANCEL/dismiss, or the trimmed new name on SAVE.
class _EditNameDialog extends StatefulWidget {
  const _EditNameDialog({required this.initialName});

  final String initialName;

  @override
  State<_EditNameDialog> createState() => _EditNameDialogState();
}

class _EditNameDialogState extends State<_EditNameDialog> {
  late final _controller = TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppConfirmDialog(
      title: 'Edit display name',
      confirmLabel: 'Save',
      cancelLabel: 'Cancel',
      onConfirm: () => Navigator.pop(context, _controller.text.trim()),
      child: DialogTextArea(
        controller: _controller,
        hint: 'Full name',
        maxLines: 1,
        // A display name with no practical bound could otherwise overflow
        // this row's single-line Text elsewhere in the app — 100
        // characters, generous for any real human name, matches the same
        // defensive-length-limit spirit as other free-text fields in this
        // codebase (e.g. ProfileSetupScreen's full-name field).
        maxLength: 100,
      ),
    );
  }
}

/// The sign-out confirmation. Mirrors `safety_page.dart`'s SOS dialog
/// styling (the one confirm-dialog pattern in this codebase). Owns the
/// sign-out call so the SIGN OUT action can turn into a spinner and lock
/// while it runs: the tap has to be seen to take, or the user taps again
/// wondering whether it did. The wait is short by design —
/// [AuthSessionNotifier.signOut] clears the local session first and does
/// the server work afterwards, in the background — but it is not zero, and
/// a button that looks idle for even a moment after a tap reads as broken.
///
/// Pops with true once signed out; the page navigates. Pops with false on
/// CANCEL, and refuses to be dismissed at all mid-sign-out.
class _SignOutDialog extends ConsumerStatefulWidget {
  const _SignOutDialog();

  @override
  ConsumerState<_SignOutDialog> createState() => _SignOutDialogState();
}

class _SignOutDialogState extends ConsumerState<_SignOutDialog> {
  bool _busy = false;

  Future<void> _signOut() async {
    if (_busy) return;
    setState(() => _busy = true);
    // Clears the local session regardless of whether the network call
    // succeeds — see AuthSessionNotifier.signOut.
    await ref.read(authSessionProvider.notifier).signOut();
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: AppConfirmDialog(
        title: 'Sign out?',
        message: 'You can sign back in with a one-time code.',
        confirmLabel: 'Sign out',
        cancelLabel: 'Cancel',
        danger: true,
        isLoading: _busy,
        onConfirm: _busy ? null : _signOut,
        onCancel: _busy ? null : () => Navigator.pop(context, false),
      ),
    );
  }
}

enum _DeleteOutcome { deleted, sessionExpired }

enum _DeletePhase { confirming, deleting, blocked }

/// Says plainly what deleting removes and what it keeps, then deletes.
///
/// A refusal from the server (meetups or requests that have not happened
/// yet) is not an error toast: it turns the sheet into the answer, with the
/// server's own sentence about what to do first. Anything else is a toast
/// and the sheet stays, so trying again is one tap. It cannot be dismissed
/// while the request is in flight: the outcome has to be seen.
class _DeleteAccountSheet extends ConsumerStatefulWidget {
  const _DeleteAccountSheet();

  @override
  ConsumerState<_DeleteAccountSheet> createState() =>
      _DeleteAccountSheetState();
}

class _DeleteAccountSheetState extends ConsumerState<_DeleteAccountSheet> {
  _DeletePhase _phase = _DeletePhase.confirming;
  String _blockedMessage = '';

  Future<void> _delete() async {
    if (_phase == _DeletePhase.deleting) return;
    setState(() => _phase = _DeletePhase.deleting);
    try {
      await ref.read(authSessionProvider.notifier).deleteAccount();
      if (mounted) Navigator.pop(context, _DeleteOutcome.deleted);
    } on AccountDeletionBlockedException catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _DeletePhase.blocked;
        _blockedMessage = error.message;
      });
    } on SessionExpiredException {
      if (mounted) Navigator.pop(context, _DeleteOutcome.sessionExpired);
    } catch (error) {
      if (!mounted) return;
      setState(() => _phase = _DeletePhase.confirming);
      showSnack(
        context,
        error is AuthException
            ? error.message
            : 'We couldn’t delete your account just now. Please try again in a moment.',
        type: ToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocked = _phase == _DeletePhase.blocked;
    return PopScope(
      canPop: _phase != _DeletePhase.deleting,
      child: AppSheet(
        // A question, not a restatement of the row that opened it. It
        // was 'Delete account', identical to the settings row — so with
        // the sheet open the screen said 'Delete account' twice and
        // neither one was obviously the confirmation. A confirmation
        // sheet should ask something.
        title: blocked ? 'Not just yet' : 'Delete your account?',
        titleColor: blocked ? AppPalette.textPrimary : AppPalette.danger,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: blocked ? _blocked(context) : _confirming(context),
        ),
      ),
    );
  }

  List<Widget> _blocked(BuildContext context) {
    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(AppIcons.calendarX, color: AppPalette.danger, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _blockedMessage,
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Text(
        'People are counting on you to be there. Once nothing is left '
        'waiting, you can delete your account from here.',
        style: TextStyle(
          color: AppPalette.textSecondary,
          fontSize: 13,
          height: 1.4,
        ),
      ),
      const SizedBox(height: 18),
      PrimaryButton(
        label: 'Got it',
        height: 50,
        onPressed: () => Navigator.pop(context),
      ),
    ];
  }

  List<Widget> _confirming(BuildContext context) {
    final deleting = _phase == _DeletePhase.deleting;
    final body = TextStyle(
      color: AppPalette.textSecondary,
      fontSize: 13,
      height: 1.4,
    );
    return [
      Text(
        'This permanently deletes your TieHere account and cannot be undone.',
        style: TextStyle(
          color: AppPalette.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
      ),
      const SizedBox(height: 12),
      _Point(
        icon: AppIcons.trash,
        text:
            'Your profile, verifications, trusted contacts, meetup history '
            'and notifications are deleted.',
        style: body,
      ),
      _Point(
        icon: AppIcons.star,
        text:
            'Ratings stay so other members’ records stay accurate, but '
            'nothing links them to you.',
        style: body,
      ),
      _Point(
        icon: AppIcons.shield,
        text:
            'If you ever sent an SOS, a private record of those alerts is '
            'kept for 90 days for safety reasons, then deleted.',
        style: body,
      ),
      _Point(
        icon: AppIcons.premium,
        text:
            'A Premium subscription is billed by the App Store or Google '
            'Play. Cancel it there to stop future charges.',
        style: body,
      ),
      const SizedBox(height: 18),
      PrimaryButton(
        label: 'Delete my account',
        height: 50,
        fillColor: AppPalette.sos,
        foregroundColor: Colors.white,
        isLoading: deleting,
        onPressed: deleting ? null : _delete,
      ),
      const SizedBox(height: 10),
      // An outline button under the red one, the pair the screen set
      // draws on every confirmation. A bare TextButton here read as a
      // caption rather than as the way out.
      SecondaryButton(
        label: 'Cancel',
        height: 50,
        onPressed: deleting ? null : () => Navigator.pop(context),
      ),
    ];
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text, required this.style});

  final String icon;
  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(icon, size: 16, color: AppPalette.textSecondary),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
  }
}
