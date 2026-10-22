import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';

/// The secondary action next to (or instead of) a [PrimaryButton] — DIDN'T
/// HAPPEN beside IT HAPPENED, Reject beside Accept, Cancel beside Save.
///
/// # IT IS FILLED NOW, NOT OUTLINED (2026-10 redesign)
///
/// This was an `OutlinedButton`: a 1px hairline around transparent, with a
/// [AppPalette.textSecondary] label. Two problems, both visible on the
/// screens where it matters most.
///
/// On the new blue-black ground a hairline outline is nearly invisible, so
/// "Cancel request" stopped looking like a control at all and started
/// looking like a caption someone had centred. And where it sits directly
/// under a green [PrimaryButton] — which is most places — the pairing read
/// as one button and one label rather than as a choice between two actions.
///
/// It is now a filled [AppPalette.raised] pill with a [AppPalette.textPrimary]
/// label: unmistakably a button, still obviously subordinate to the green
/// one, and the same stadium shape so the pair reads as a set.
///
/// [borderColor] is kept and still draws an outline when passed, because the
/// destructive variants (`color: AppPalette.danger`) use it to read as a
/// warning without taking a full red fill.
class SecondaryButton extends StatefulWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.height = 56,
    this.color,
    this.borderColor,
    this.fillColor,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final double height;

  /// Optional leading icon, mirroring [PrimaryButton.icon] so the two button
  /// styles stay interchangeable at a call site.
  final String? icon;

  /// Defaults resolved in [build], not as compile-time default parameter
  /// values — [AppPalette]'s fields are theme-aware getters (Slice G), not
  /// `const`s, so a `const` default value can't reference them anymore.
  final Color? color;
  final Color? borderColor;

  /// Overrides the [AppPalette.raised] fill. Pass
  /// `Colors.transparent` for the rare case that genuinely wants a bare
  /// outline (a tertiary action inside an already-raised sheet, where a
  /// second raised surface on top of the first would disappear).
  final Color? fillColor;

  @override
  State<SecondaryButton> createState() => _SecondaryButtonState();
}

class _SecondaryButtonState extends State<SecondaryButton> {
  bool _pressed = false;

  void _set(bool v) {
    if (mounted) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onPressed != null;
    final Color fg = widget.color ?? AppPalette.textPrimary;
    final Color fill = widget.fillColor ?? AppPalette.raised;
    // Matches PrimaryButton exactly so a stacked pair shares one corner.
    final double radius = widget.height / 2 > 28 ? 28 : widget.height / 2;

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      // excludeSemantics drops the descendants' nodes — the inner Text's
      // (which would make this announce as "SKIP SKIP") and the
      // GestureDetector's, which is where the tap action came from. So the
      // action is re-declared here, from the same nullable callback, and
      // is therefore absent exactly when the button is disabled.
      excludeSemantics: true,
      onTap: widget.onPressed,
      child: GestureDetector(
        // All four are null when disabled, not just onTap. GestureDetector
        // derives its semantics tap action from onTapDown/onTapUp as well,
        // so leaving the press-feedback handlers wired left a disabled
        // button advertising itself as tappable to a screen reader even
        // though nothing happened when it was activated.
        onTapDown: enabled ? (_) => _set(true) : null,
        onTapUp: enabled ? (_) => _set(false) : null,
        onTapCancel: enabled ? () => _set(false) : null,
        onTap: widget.onPressed,
        child: AnimatedScale(
          scale: _pressed ? 1.02 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Opacity(
            opacity: enabled ? 1 : 0.45,
            child: Container(
              width: double.infinity,
              height: widget.height,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(radius),
                border: widget.borderColor == null
                    ? null
                    : Border.all(color: widget.borderColor!),
              ),
              // Shrinks rather than ellipsizing, for the same reason
              // PrimaryButton does: a truncated label on a narrow device
              // reads as broken.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.icon != null) ...[
                      AppIcon(widget.icon!, size: 18, color: fg),
                      const SizedBox(width: 10),
                    ],
                    Text(
                      widget.label,
                      maxLines: 1,
                      style: TextStyle(
                        color: fg,
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
