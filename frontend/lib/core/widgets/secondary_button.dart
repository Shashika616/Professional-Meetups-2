import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The secondary/outlined counterpart to [PrimaryButton] — used wherever a
/// less-emphasized action sits next to (or instead of) a primary button
/// (DIDN'T HAPPEN next to IT HAPPENED, REJECT next to ACCEPT, SKIP next to
/// SAVE, CANCEL/CLOSE MEETUP). Previously each call site hand-rolled its own
/// `OutlinedButton.styleFrom(...)` with slightly different fonts/weights and
/// no overflow handling at all; unified here for the same reason
/// [PrimaryButton]'s label shrinks instead of ellipsizing — a long label
/// getting cut off to "...", or a bare `Text` silently overflowing its
/// button, looks unprofessional on a narrow device (first reported on iOS).
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.height = 56,
    this.color,
    this.borderColor,
  });

  final String label;
  final VoidCallback? onPressed;
  final double height;

  /// Defaults resolved in [build], not as compile-time default parameter
  /// values — [AppPalette]'s fields are theme-aware getters (Slice G), not
  /// `const`s, so a `const` default value can't reference them anymore.
  final Color? color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: Size.fromHeight(height),
        side: BorderSide(color: borderColor ?? AppPalette.hairline),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          label,
          maxLines: 1,
          style: TextStyle(
            color: color ?? AppPalette.textSecondary,
            fontWeight: FontWeight.w700,
            fontSize: 13,
            letterSpacing: 0.6,
          ),
        ),
      ),
    );
  }
}
