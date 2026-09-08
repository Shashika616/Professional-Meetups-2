import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';

/// Host-only Cancel/Close actions, extracted so this logic exists once
/// instead of duplicated between [MeetupDetailPage] and the "Hosting" tab's
/// request-management screen (ADR-016 addendum, 2026-08-20) — that
/// duplication is exactly what stranded hosts on a screen that couldn't
/// close or cancel anything before this fix. Renders whichever of
/// CANCEL/CLOSE actually apply given [meetup]'s current status/window/
/// accepted count; renders nothing if neither applies.
class HostMeetupControls extends ConsumerWidget {
  const HostMeetupControls({
    super.key,
    required this.meetup,
    required this.onChanged,
  });

  final Meetup meetup;

  /// Called with the updated [Meetup] after a successful Cancel or Close.
  final ValueChanged<Meetup> onChanged;

  bool get _isOpenOrFull =>
      meetup.status == MeetupStatus.open || meetup.status == MeetupStatus.full;

  /// Only once the window has actually started; not forced to wait for
  /// windowEnd, since real meetups run long or short (ADR-016). windowStart
  /// can be null (ADR-028 — GetMeetup redacts too as of round-5/6
  /// hardening); `isHostedByMe` short-circuits first so this already
  /// couldn't reach a null windowStart today (the round-6 participation
  /// exception means a host's own meetup is never redacted for them,
  /// meaning isHostedByMe and a null windowStart can't co-occur) — checked
  /// explicitly anyway rather than leaning on that chain, so this stays
  /// correct even if something upstream changes later.
  bool get _canClose {
    final windowStart = meetup.windowStart;
    return meetup.isHostedByMe &&
        _isOpenOrFull &&
        windowStart != null &&
        DateTime.now().isAfter(windowStart);
  }

  /// Cancelling with accepted participants is allowed as of ADR-020 §3
  /// (widened from the original zero-accepted precondition) — the backend
  /// now notifies every accepted requester instead of rejecting the
  /// request, and requires a reason (captured in [_confirmCancel]'s
  /// dialog) that's included in that notification.
  bool get _canCancel => meetup.isHostedByMe && _isOpenOrFull;

  Future<void> _confirmClose(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppPalette.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'CLOSE MEETUP',
          style: TextStyle(
            color: AppPalette.textPrimary,
            letterSpacing: 1.6,
            fontSize: 15,
          ),
        ),
        content: Text(
          'Mark this meetup as done?',
          style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'CANCEL',
              style: TextStyle(color: AppPalette.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              'CONFIRM',
              style: TextStyle(
                color: AppPalette.candyBlue,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    await _close(context, ref);
  }

  Future<void> _close(BuildContext context, WidgetRef ref) async {
    try {
      final closed = await ref
          .read(meetupServiceProvider)
          .closeMeetup(meetup.id);
      if (!context.mounted) return;
      onChanged(closed);
      showSnack(context, 'Meetup closed.', type: ToastType.success);
    } catch (error) {
      if (context.mounted) {
        showSnack(
          context,
          error is MeetupException
              ? error.message
              : 'Something went wrong. Please try again.',
          type: ToastType.error,
        );
      }
    }
  }

  Future<void> _confirmCancel(BuildContext context, WidgetRef ref) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => const _CancelReasonDialog(),
    );
    if (reason == null) return;
    if (!context.mounted) return;
    await _cancel(context, ref, reason);
  }

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    String reason,
  ) async {
    try {
      await ref
          .read(meetupServiceProvider)
          .cancelMeetup(meetup.id, reason: reason);
      if (!context.mounted) return;
      // cancelMeetup only returns {success: true} server-side — no updated
      // Meetup to re-render from, unlike closeMeetup. Constructing the
      // post-cancel state locally here is the exception to this app's
      // usual "client never decides, only displays" rule; it's applying a
      // known, deterministic transition after a request the server has
      // already confirmed succeeded, not guessing at server-side state.
      onChanged(
        meetup.copyWith(
          status: MeetupStatus.cancelled,
          cancelledAt: DateTime.now(),
          cancellationReason: reason,
        ),
      );
      showSnack(context, 'Meetup cancelled.', type: ToastType.success);
    } catch (error) {
      if (context.mounted) {
        showSnack(
          context,
          error is MeetupException
              ? error.message
              : 'Something went wrong. Please try again.',
          type: ToastType.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canClose = _canClose;
    final canCancel = _canCancel;
    if (!canClose && !canCancel) return const SizedBox.shrink();

    final closeButton = SecondaryButton(
      label: 'CLOSE MEETUP',
      height: 44,
      color: AppPalette.textPrimary,
      onPressed: () => _confirmClose(context, ref),
    );

    final cancelButton = SecondaryButton(
      label: 'CANCEL MEETUP',
      height: 44,
      color: AppPalette.danger,
      borderColor: AppPalette.danger,
      onPressed: () => _confirmCancel(context, ref),
    );

    // Top padding lives here, not as a sibling SizedBox at each call site,
    // so callers don't end up with a stray gap when neither action applies
    // and this widget renders nothing.
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: canClose && canCancel
          // Same narrow-device/long-label overflow class the PrimaryButton
          // fix addressed — SecondaryButton shrinks its label to fit for
          // the same reason, since two side-by-side buttons is exactly the
          // layout that originally surfaced that bug.
          ? Row(
              children: [
                Expanded(child: cancelButton),
                const SizedBox(width: 10),
                Expanded(child: closeButton),
              ],
            )
          : (canClose ? closeButton : cancelButton),
    );
  }
}

/// The cancel-with-reason dialog (ADR-020 §3), split out as its own
/// [StatefulWidget] so its [TextEditingController] is disposed through the
/// State's own `dispose()` — tied to the dialog route's actual removal from
/// the tree — rather than disposed manually right after `showDialog`
/// resolves. That manual-dispose pattern raced the dialog's exit
/// transition (which keeps rebuilding the TextField for a frame or two
/// after the route pops) and threw "A TextEditingController was used after
/// being disposed," caught by the widget tests added alongside this dialog.
class _CancelReasonDialog extends StatefulWidget {
  const _CancelReasonDialog();

  @override
  State<_CancelReasonDialog> createState() => _CancelReasonDialogState();
}

class _CancelReasonDialogState extends State<_CancelReasonDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final trimmed = _controller.text.trim();
    return AlertDialog(
      backgroundColor: AppPalette.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        'CANCEL MEETUP',
        style: TextStyle(
          color: AppPalette.danger,
          letterSpacing: 1.6,
          fontSize: 15,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Cancel this meetup? This can\'t be undone. Accepted '
            'participants will be notified with your reason.',
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            onChanged: (_) => setState(() {}),
            maxLines: 3,
            style: TextStyle(color: AppPalette.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Reason for cancelling (required)',
              hintStyle: TextStyle(color: AppPalette.textSecondary),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'BACK',
            style: TextStyle(color: AppPalette.textSecondary),
          ),
        ),
        TextButton(
          onPressed: trimmed.isEmpty
              ? null
              : () => Navigator.pop(context, trimmed),
          child: Text(
            'CANCEL MEETUP',
            // Greyed while disabled. `onPressed: null` already blocks the
            // tap, but an explicit `style:` overrides TextButton's own
            // disabled colour, so the control looked fully active while
            // doing nothing — the user reads that as a broken button, not
            // as "fill the field in".
            style: TextStyle(
              color: trimmed.isEmpty
                  ? AppPalette.textSecondary.withValues(alpha: 0.45)
                  : AppPalette.danger,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}
