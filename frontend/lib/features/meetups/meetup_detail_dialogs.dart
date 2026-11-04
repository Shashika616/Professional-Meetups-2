part of 'meetup_detail_page.dart';

/// The withdraw-confirmation-with-optional-note dialog (ADR-020 §4), split
/// out as its own [StatefulWidget] for the same reason
/// `host_meetup_controls.dart`'s `_CancelReasonDialog` is — a
/// [TextEditingController] disposed manually right after `showDialog`
/// resolves races the dialog's exit transition and throws "used after
/// being disposed." Owning the controller in the State and disposing it in
/// `dispose()` ties disposal to the widget's actual removal instead.
/// Resolves to null on BACK/dismiss, or the (possibly empty) note text on
/// WITHDRAW.
/// Confirmation for cancelling a still-pending request. No note field:
/// the host has not acted, is not told, and there is nobody to explain
/// anything to.
class _CancelRequestDialog extends StatelessWidget {
  const _CancelRequestDialog();

  @override
  Widget build(BuildContext context) {
    return AppConfirmDialog(
      title: 'Cancel request',
      message:
          'Take back your request to join? The host has not answered yet, '
          'so nothing is sent to them. You can request again any time.',
      confirmLabel: 'Cancel request',
      cancelLabel: 'Keep it',
      danger: true,
      onConfirm: () => Navigator.pop(context, true),
      onCancel: () => Navigator.pop(context, false),
    );
  }
}

class _WithdrawNoteDialog extends StatefulWidget {
  const _WithdrawNoteDialog();

  @override
  State<_WithdrawNoteDialog> createState() => _WithdrawNoteDialogState();
}

class _WithdrawNoteDialogState extends State<_WithdrawNoteDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppConfirmDialog(
      title: 'Withdraw request',
      message: 'Withdraw your request to join this meetup?',
      confirmLabel: 'Withdraw request',
      cancelLabel: 'Back',
      danger: true,
      onConfirm: () => Navigator.pop(context, _controller.text.trim()),
      child: DialogTextArea(
        controller: _controller,
        hint: 'Note for the host (optional)',
      ),
    );
  }
}

/// The decline-with-reason dialog (ADR-024 §4) — mirrors
/// `host_meetup_controls.dart`'s `_CancelReasonDialog` exactly: a
/// [StatefulWidget] owning its own [TextEditingController], disposed
/// through the State's own `dispose()` rather than manually right after
/// `showDialog` resolves (which races the dialog's exit transition and
/// throws "A TextEditingController was used after being disposed" —
/// `_CancelReasonDialog`'s and `_WithdrawNoteDialog`'s own doc comments
/// document the same bug this pattern avoids). Reason is required — the
/// confirm button stays disabled until non-empty, same as
/// `_CancelReasonDialog`. Resolves to null on BACK/dismiss, or the trimmed
/// reason on DECLINE.
class _DeclineReasonDialog extends StatefulWidget {
  const _DeclineReasonDialog();

  @override
  State<_DeclineReasonDialog> createState() => _DeclineReasonDialogState();
}

class _DeclineReasonDialogState extends State<_DeclineReasonDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final trimmed = _controller.text.trim();
    return AppConfirmDialog(
      title: 'Decline',
      message:
          'Decline this meetup\'s safety checklist? The host will be '
          'notified with your reason.',
      confirmLabel: 'Decline',
      cancelLabel: 'Back',
      danger: true,
      // Null while the reason is empty, which leaves the confirm button
      // dimmed and inert rather than looking live and doing nothing.
      onConfirm: trimmed.isEmpty ? null : () => Navigator.pop(context, trimmed),
      child: DialogTextArea(
        controller: _controller,
        hint: 'Reason for declining (required)',
        onChanged: (_) => setState(() {}),
      ),
    );
  }
}

class _DoneRow extends StatelessWidget {
  const _DoneRow(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        AppIcon(AppIcons.checkCircle, size: 16, color: AppPalette.verified),
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            color: AppPalette.verified,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

/// The declined terminal state (ADR-024 §4) — same spirit as `_DoneRow`
/// (a static row, no longer offering check-in), danger-colored like every
/// other cancelled/withdrawn state already shown elsewhere in this app,
/// not a new visual language.
