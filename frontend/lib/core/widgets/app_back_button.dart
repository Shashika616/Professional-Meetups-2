import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';

/// The one back control for any screen that draws its own.
///
/// # WHY THIS EXISTS
///
/// Most pages here sit under an `AppBar` and get Flutter's implicit back
/// button, which is already consistent and already platform-correct. The
/// screens that draw their own header were each solving it again, and had
/// drifted into four different answers:
///
///   - an iOS chevron hardcoded (schedule flow, onboarding), shown to
///     Android users too;
///   - an Android arrow hardcoded (the map overlay), shown to iOS users
///     too;
///   - the implicit `AppBar` one everywhere else, which is right on both;
///   - and nothing at all on the four verification pages, which had only a
///     "Skip for now" in the opposite corner.
///
/// So on an Android phone the app showed an Android arrow on most screens
/// and an iOS chevron on two of them, and on an iPhone the reverse. Every
/// screen now takes its glyph from [backButtonIconPath], which still makes
/// the platform distinction — a chevron on iOS, an arrow on Android.
///
/// It used to render Material's own [BackButtonIcon]. That was right while
/// the rest of the app was on Material glyphs; now that every other icon
/// comes from the authored stroke set, a single font glyph here was the
/// one control drawn in a different weight from everything beside it.
///
/// # THE TOOLTIP IS NOT OPTIONAL
///
/// An unlabelled icon button is announced to a screen reader as "button"
/// and nothing else. `AppBar`'s own back button is labelled from
/// [MaterialLocalizations.backButtonTooltip]; this uses the same string, so
/// it is announced identically and translates with the rest of the app
/// rather than carrying a hardcoded English word.
class AppBackButton extends StatelessWidget {
  const AppBackButton({super.key, this.onPressed});

  /// What back means on this screen.
  ///
  /// Null uses `Navigator.maybePop`, which is what `AppBar`'s button does:
  /// it respects a `PopScope` rather than tearing the route down underneath
  /// one. A flow with internal steps (onboarding, the schedule flow) passes
  /// its own handler so the arrow walks back through those steps first.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final label = MaterialLocalizations.of(context).backButtonTooltip;
    return IconButton(
      onPressed: onPressed ?? () => Navigator.maybePop(context),
      tooltip: label,
      // 18 to match the size the custom headers already used, so adopting
      // this does not move anything; the ICON is what changes.
      iconSize: 18,
      color: AppPalette.textPrimary,
      icon: AppIcon(
        backButtonIconPath(context),
        size: 18,
        color: AppPalette.textPrimary,
      ),
    );
  }
}

/// The platform's back glyph, as an [AppIcons] path, for the places that
/// need the glyph rather than a whole button — the map overlay draws its
/// own circular chrome for contrast against the map and only wants the
/// icon inside it.
///
/// Kept beside [AppBackButton] on purpose: two ways to get a back icon is
/// one too many, and if they live together they cannot disagree.
///
/// iOS gets a bare chevron and Android an arrow with a shaft, which is
/// what each platform's users read as "back". The stroke set has both, so
/// moving off Material's glyphs did not cost the distinction.
String backButtonIconPath(BuildContext context) {
  switch (Theme.of(context).platform) {
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return AppIcons.back;
    case TargetPlatform.android:
    case TargetPlatform.fuchsia:
    case TargetPlatform.linux:
    case TargetPlatform.windows:
      return AppIcons.arrowLeft;
  }
}
