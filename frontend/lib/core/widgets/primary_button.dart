import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The shared primary CTA button (ADR-032 — replaces the old gradient-fill
/// button widget this file used to define). Solid `AppPalette.candyBlue`
/// fill, not a `candyBlue→steelBlue` gradient; no colored glow shadow that
/// grows on press. Press feedback is a smaller scale bump than before
/// (1.0 → 1.02, was 1.03) — calmer, since there's no shadow doing visual
/// work anymore either. Same constructor shape as before
/// (`label`/`onPressed`/`height`/`isLoading`/`icon`) so every call site
/// only needed a rename.
class PrimaryButton extends StatefulWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.height = 56,
    this.isLoading = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final double height;
  final bool isLoading;
  final IconData? icon;

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

  @override
  Widget build(BuildContext context) {
    final bool isEnabled = widget.onPressed != null && !widget.isLoading;
    // Fixed 12, NOT height / 2 (ADR-032 round 2). The old formula always
    // produced a full stadium/pill — half of the height is by definition a
    // fully-rounded capsule — so round 1's rename left every primary CTA
    // still reading as a glass-era pill no matter what height a call site
    // passed. 12 matches the reference image's card/button radius.
    const double borderRadius = 12;

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
              color: isEnabled
                  ? AppPalette.candyBlue
                  : AppPalette.candyBlue.withValues(alpha: 0.4),
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
                          color: AppPalette.onyx,
                        ),
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.icon != null) ...[
                            Icon(widget.icon, size: 20, color: AppPalette.onyx),
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
                                  color: AppPalette.onyx,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.5,
                                  fontSize: 15,
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
