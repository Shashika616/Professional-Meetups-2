import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';

/// The app's single text input. Was `GlassTextField`, in
/// `glass_text_field.dart` — a name that had outlived two redesigns and
/// described a translucency the app has not had since ADR-032.
///
/// # THE LABEL STAYS PUT NOW
///
/// This used to be `icon + hintText`: an accent-coloured glyph, and a grey
/// placeholder that VANISHED the moment you typed. That is the oldest
/// usability bug in form design — once the field is filled, nothing on
/// screen says what it is, so anyone reviewing a filled-in form (the
/// profile setup screen has four fields; the schedule flow has five) has to
/// infer each value's meaning from the value itself. It is worst exactly
/// where it matters most: two adjacent fields reading `name@company.com`
/// and `you@gmail.com` with no labels are indistinguishable.
///
/// The screen set specifies a persistent caption above the value, which is
/// Material's floating label. So [hint] is now a LABEL: it sits in the
/// middle of an empty field, and shrinks to a caption at the top once there
/// is content or focus. Nothing at the call sites changed — the same string
/// that was the placeholder is the label — they just stopped losing it.
///
/// The leading [icon] is kept, because the call sites pass one and several
/// genuinely benefit (the phone field, the search field), but it is drawn in
/// [AppPalette.textTertiary] rather than the accent. A column of five
/// accent-blue glyphs made the icons the loudest thing on a form, competing
/// with the one blue thing that was supposed to be loud.
class AppTextField extends StatelessWidget {
  const AppTextField({
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
  final String icon;

  /// The field's label. Named `hint` for the same reason the class kept its
  /// constructor shape: renaming it would have touched every call site to
  /// say the same thing.
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
  // (not just hidden) until a company name is entered.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final Color labelColor = enabled
        ? AppPalette.textSecondary
        : AppPalette.textTertiary.withValues(alpha: 0.6);

    return FlatCard(
      radius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 14),
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
        cursorColor: AppPalette.candyBlue,
        style: TextStyle(
          color: enabled
              ? AppPalette.textPrimary
              : AppPalette.textSecondary.withValues(alpha: 0.5),
          fontSize: 15.5,
          fontWeight: FontWeight.w500,
          letterSpacing: letterSpacing,
        ),
        decoration: InputDecoration(
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
          counterText: '',
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          // labelText, not hintText — see the class doc.
          labelText: hint,
          labelStyle: TextStyle(
            color: labelColor,
            fontSize: 15.5,
            letterSpacing: 0,
          ),
          floatingLabelStyle: TextStyle(
            color: AppPalette.candyBlue,
            fontSize: 15.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
          ),
          errorStyle: TextStyle(color: AppPalette.danger, fontSize: 11.5),
          icon: AppIcon(icon, color: AppPalette.textTertiary, size: 19),
        ),
        validator: validator,
      ),
    );
  }
}
