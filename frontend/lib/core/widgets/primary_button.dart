import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';

/// The shared primary CTA button.
///
/// # IT IS GREEN, AND IT IS A PILL (2026-10 redesign)
///
/// Both of those reverse an earlier decision (ADR-032), so both are worth
/// the lines.
///
/// **Green.** The fill was [AppPalette.candyBlue]. Blue is also the colour of
/// every link, every selected chip, every field icon and the active nav
/// item, so on a screen with three blue things none of them was obviously
/// *the button*. [AppPalette.solid] is used for one thing and nothing else,
/// and the eye finds it without reading.
///
/// **Pill.** The radius was a fixed 12, chosen when the app was flattening
/// away from a glass-era capsule. The redesign goes back to a stadium
/// because with a solid green fill the shape is no longer what distinguishes
/// a button from a card — the colour is. A 12px green slab reads as a
/// banner. It is `height / 2` CAPPED AT 28, not the bare half-height the
/// pre-ADR-032 code used: an unbounded half-height turns a tall button (a
/// wrapped label, a 72px step CTA) into an oval instead of leaving it a
/// consistent corner.
///
/// Press feedback stays a 1.02 scale bump with no glow. The constructor
/// shape (`label`/`onPressed`/`height`/`isLoading`/`icon`) is unchanged.
class PrimaryButton extends StatefulWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.height = 56,
    this.isLoading = false,
    this.icon,
    this.iconWidget,
    this.fillColor,
    this.foregroundColor,
    this.borderColor,
  });

  final String label;
  final VoidCallback? onPressed;
  final double height;
  final bool isLoading;
  final String? icon;

  /// A leading icon that is not a font glyph — used for logos that carry
  /// their own colours, which an [Icon] cannot express (Google's mark is
  /// four colours; a glyph can only ever be one). Wins over [icon].
  final Widget? iconWidget;

  /// Overrides for the default [AppPalette.solid] fill. The provider sign-in buttons
  /// use a NEUTRAL surface: Apple's HIG and Google's Sign-In branding both
  /// expect their logo on a plain light or dark button, and a four-colour
  /// mark on a tinted fill reads as muddy regardless of the rules.
  final Color? fillColor;
  final Color? foregroundColor;
  final Color? borderColor;

  @override
  State<PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<PrimaryButton> {
  bool _isPressed = false;

  void _onTapDown(TapDownDetails details) {
    if (widget.onPressed != null && !widget.isLoading) {
      setState(() => _isPressed = true);
    }
  }

  void _onTapUp(TapUpDetails details) {
    if (mounted) setState(() => _isPressed = false);
  }

  void _onTapCancel() {
    if (mounted) setState(() => _isPressed = false);
  }

  /// The label colour. Disabled is [AppPalette.textTertiary] on the
  /// neutral fill, not [AppPalette.solidFg], which only reads against the
  /// green.
  Color _fg(bool isEnabled) =>
      isEnabled ? AppPalette.solidFg : AppPalette.textTertiary;

  @override
  Widget build(BuildContext context) {
    final bool isEnabled = widget.onPressed != null && !widget.isLoading;
    // Fixed 12, NOT height / 2 (ADR-032 round 2). The old formula always
    // produced a full stadium/pill — half of the height is by definition a
    // fully-rounded capsule — so round 1's rename left every primary CTA
    // still reading as a glass-era pill no matter what height a call site
    // passed. 12 matches the reference image's card/button radius.
    final double borderRadius = widget.height / 2 > 28 ? 28 : widget.height / 2;

    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      onTap: isEnabled ? widget.onPressed : null,
      child: AnimatedScale(
        scale: _isPressed ? 1.02 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(borderRadius),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius),
              // Solid fill, no gradient, no glow — flat (ADR-032).
              //
              // The disabled fill used to be the SAME green at 40% alpha,
              // with the same near-black label on top. On the dark theme
              // that composites to a muddy dark green and the label all
              // but vanishes — "Send code" and "Verify" were unreadable
              // until the form was valid, which is exactly when a user is
              // looking at them. Disabled is now an opaque neutral
              // surface with a muted label: it reads as "not yet", not as
              // a rendering fault.
              color: isEnabled
                  ? (widget.fillColor ?? AppPalette.solid)
                  : AppPalette.raised,
              // Only the neutral provider buttons ask for one; the default
              // filled button needs no outline against the page.
              border: widget.borderColor == null
                  ? null
                  : Border.all(color: widget.borderColor!),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(borderRadius),
              onTap: isEnabled ? widget.onPressed : null,
              child: Container(
                width:
                    double.infinity, // Forces the fill to cover the whole width
                height: widget.height,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: widget.isLoading
                    ? SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: widget.foregroundColor ?? _fg(isEnabled),
                        ),
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.iconWidget != null) ...[
                            widget.iconWidget!,
                            const SizedBox(width: 12),
                          ] else if (widget.icon != null) ...[
                            AppIcon(
                              widget.icon!,
                              size: 20,
                              color: widget.foregroundColor ?? _fg(isEnabled),
                            ),
                            const SizedBox(width: 12),
                          ],
                          // Shrinks the label to fit instead of ellipsizing
                          // it — a truncated "IT HAPPE..." on a narrower
                          // device (first reported on iOS; never seen on the
                          // wider Android device this was originally tested
                          // against) reads as broken/unprofessional in a
                          // way a smaller-but-complete label doesn't.
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                widget.label,
                                maxLines: 1,
                                style: TextStyle(
                                  color:
                                      widget.foregroundColor ?? _fg(isEnabled),
                                  fontWeight: FontWeight.w700,
                                  // 15 sat level with a 20px logo, so the
                                  // two competed. 13.5 keeps the label
                                  // clearly secondary to the mark it
                                  // follows, which is how these buttons
                                  // read in every app that ships them.
                                  letterSpacing: 0.2,
                                  fontSize: 14.5,
                                ),
                              ),
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
