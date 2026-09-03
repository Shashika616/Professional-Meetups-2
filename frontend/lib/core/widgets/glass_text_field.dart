import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';

class GlassTextField extends StatelessWidget {
  const GlassTextField({
    super.key,
    required this.controller,
    required this.icon,
    required this.hint,
    this.keyboardType,
    this.validator,
    this.maxLength,
    this.textAlign = TextAlign.left,
    this.letterSpacing,
    this.textInputAction,
    this.onFieldSubmitted,
    this.obscureText = false,
    this.enabled = true,
  });

  final TextEditingController controller;
  final IconData icon;
  final String hint;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final int? maxLength;
  final TextAlign textAlign;
  final double? letterSpacing;
  final TextInputAction? textInputAction;
  // A location search field's "type a full query and press search/return"
  // path (frontend/meetup-scheduling-PLAN.md's 2026-08-18 platform-split
  // addendum, Step 2) — optional, every other caller of this field leaves
  // it null and gets the previous behavior unchanged.
  final void Function(String)? onFieldSubmitted;
  // Email-OTP signup/login (ADR-014 decision #2) — optional, defaults to
  // false so every existing caller is unaffected.
  final bool obscureText;

  // The profile-setup screen's company-email field (ADR-019 §2) — disabled
  // (not just hidden) until a company name is entered. Optional, defaults
  // to true so every existing caller is unaffected.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return FlatCard(
      radius: 12,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        textAlign: textAlign,
        autocorrect: false,
        maxLength: maxLength,
        textInputAction: textInputAction,
        onFieldSubmitted: onFieldSubmitted,
        obscureText: obscureText,
        enabled: enabled,
        style: TextStyle(
          color: enabled
              ? AppPalette.textPrimary
              : AppPalette.textSecondary.withValues(alpha: 0.5),
          fontSize: 16,
          letterSpacing: letterSpacing,
        ),
        decoration: InputDecoration(
          border: InputBorder.none,
          counterText: '',
          hintText: hint,
          hintStyle: TextStyle(
            color: AppPalette.textSecondary,
            letterSpacing: 0,
          ),
          icon: Icon(icon, color: AppPalette.candyBlue, size: 20),
        ),
        validator: validator,
      ),
    );
  }
}
