import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';

/// [showDialog] with the one-tap-one-modal guard that `showAppSheet`
/// already has — see `app_sheet.dart` for the full reasoning, which is
/// identical here.
///
/// # WHY A SECOND WRAPPER RATHER THAN ONE
///
/// Sheets and dialogs arrive differently on purpose (`app_sheet.dart`
/// explains which moments get which), so they stay two functions. The
/// GUARD is the part that must not be duplicated per call site, and it
/// isn't: there is exactly one copy of it per presentation, and both read
/// the same signal.
///
/// A second tap landing before the first dialog has finished its fade used
/// to push a second copy of it. For the dialogs behind this function that
/// is not just a cosmetic double: two sign-out confirmations, two
/// remove-contact confirmations, or two CONFIRM RATING dialogs mean the
/// user answers a question they have already answered, and the second
/// answer lands on a screen whose state the first one already changed.
///
/// It reads the CALLER's route: pushing a dialog makes that route stop
/// being the current one, so "my route is no longer on top" means
/// something is already covering this caller and a tap arriving now is one
/// the user cannot have meant. A dialog opened from inside a sheet still
/// works — there the caller's route IS the sheet, which is current.
///
/// Returns null when it declines, which is what every call site already
/// treats as "dismissed, do nothing".
Future<T?> showAppDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final route = ModalRoute.of(context);
  if (route != null && !route.isCurrent) return Future<T?>.value(null);
  return showDialog<T>(
    context: context,
    builder: builder,
    barrierDismissible: barrierDismissible,
  );
}

/// The app's confirmation dialog, replacing the raw [AlertDialog]s that
/// every destructive confirmation used to build inline.
///
/// # WHY IT EXISTS
///
/// An `AlertDialog` brings Material's own chrome with it: a tight title,
/// a trailing row of flat text buttons, and — wherever one carried an
/// input — an underlined `TextField` in the framework's default colours.
/// Next to the rest of the app that read as a system alert that had
/// wandered in from another product. The screen set draws these as a
/// plain card: title, one line of explanation, then the two choices as
/// full-width stacked buttons, the destructive one solid and on top.
///
/// Stacked, not side by side: the confirming label is the long one
/// ("Delete my account", "Withdraw request"), and a two-column row either
/// shrinks it or wraps it.
class AppConfirmDialog extends StatelessWidget {
  const AppConfirmDialog({
    super.key,
    required this.title,
    required this.confirmLabel,
    required this.cancelLabel,
    this.message,
    this.bullets = const [],
    this.child,
    this.danger = false,
    this.onConfirm,
    this.onCancel,
    this.isLoading = false,
  });

  final String title;
  final String? message;

  /// Consequence lines, drawn with a dot each — the shape the screen set
  /// uses wherever a confirmation has to spell out what it takes with it
  /// (Delete account, Before you go).
  final List<String> bullets;

  /// Anything the dialog needs between the copy and the buttons: the one
  /// case today is a note/reason field.
  final Widget? child;

  final String confirmLabel;
  final String cancelLabel;

  /// Solid red confirm button. Everything behind this flag destroys
  /// something the user cannot get back.
  final bool danger;

  /// Null leaves the confirm button disabled — a reason field that is
  /// still empty, for instance.
  final VoidCallback? onConfirm;
  final VoidCallback? onCancel;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppPalette.card,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w800,
                height: 1.25,
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
            ],
            if (bullets.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final line in bullets)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        // Optically centred on the first line of text,
                        // not on the paragraph: a dot that floats down
                        // beside a two-line consequence reads as a bullet
                        // for the wrong line.
                        margin: const EdgeInsets.only(top: 7, right: 10),
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color: AppPalette.textSecondary,
                          shape: BoxShape.circle,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          line,
                          style: TextStyle(
                            color: AppPalette.textSecondary,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            if (child != null) ...[const SizedBox(height: 14), child!],
            const SizedBox(height: 18),
            PrimaryButton(
              label: confirmLabel,
              height: 48,
              isLoading: isLoading,
              fillColor: danger ? AppPalette.danger : null,
              // Only while it is live. PrimaryButton mutes its own label
              // when disabled, and an explicit white overrode that — on
              // light, a white label on the disabled neutral fill was
              // invisible until the required field was filled in, which
              // is exactly when the user is looking for it.
              foregroundColor: danger && onConfirm != null
                  ? Colors.white
                  : null,
              onPressed: onConfirm,
            ),
            const SizedBox(height: 10),
            SecondaryButton(
              label: cancelLabel,
              height: 48,
              onPressed: onCancel ?? () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// [showAppDialog] with an [AppConfirmDialog] in it — the shape almost
/// every call site wants. Resolves to true on confirm, null on dismiss.
Future<bool?> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  required String cancelLabel,
  String? message,
  List<String> bullets = const [],
  bool danger = false,
}) {
  return showAppDialog<bool>(
    context,
    builder: (dialogContext) => AppConfirmDialog(
      title: title,
      message: message,
      bullets: bullets,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      danger: danger,
      onConfirm: () => Navigator.pop(dialogContext, true),
      onCancel: () => Navigator.pop(dialogContext, false),
    ),
  );
}

/// The multi-line field an [AppConfirmDialog] takes as its [child] — a
/// withdrawal note, a cancellation reason.
///
/// [AppTextField] is the app's field everywhere else, but it is one line
/// with a leading glyph, which is the wrong shape for a paragraph. This
/// keeps the same raised-box-on-card look without the glyph: Material's
/// underlined default, which these two dialogs used to draw, is the one
/// piece of framework chrome that survives a dark theme looking like a
/// different app.
class DialogTextArea extends StatelessWidget {
  const DialogTextArea({
    super.key,
    required this.controller,
    required this.hint,
    this.maxLines = 3,
    this.maxLength,
    this.onChanged,
  });

  final TextEditingController controller;
  final String hint;
  final int maxLines;
  final int? maxLength;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppPalette.raised,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        maxLength: maxLength,
        onChanged: onChanged,
        style: TextStyle(
          color: AppPalette.textPrimary,
          fontSize: 13.5,
          height: 1.4,
        ),
        decoration: InputDecoration(
          border: InputBorder.none,
          counterText: '',
          hintText: hint,
          hintStyle: TextStyle(color: AppPalette.textSecondary, fontSize: 13.5),
        ),
      ),
    );
  }
}
