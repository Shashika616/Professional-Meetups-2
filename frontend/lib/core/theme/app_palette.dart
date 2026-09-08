import 'package:flutter/material.dart';

/// The two theme modes this app supports (Slice G) — deliberately just
/// dark/light, not `ThemeMode.system`: [ThemeModeNotifier] in
/// `app_providers.dart` defaults every existing user to dark on first
/// launch of this update, not whatever their OS brightness happens to be.
enum AppThemeMode { dark, light }

/// Every color in this app as a `static` getter, dispatching on
/// [AppPalette.mode] — was `static const Color` before Slice G. This is
/// the load-bearing design choice that lets all ~350 existing
/// `AppPalette.someColor` call sites across the app keep compiling and
/// working completely unmodified (aside from any that embedded a color
/// inside a `const` widget constructor, which a non-const getter can no
/// longer satisfy — those few call sites had their local `const` dropped,
/// nothing else). [setMode] is called by [ThemeModeNotifier]
/// (`app_providers.dart`) whenever the toggle flips or the persisted
/// preference loads; the actual widget-rebuild-on-change mechanism lives
/// in `main.dart` (a static field write alone doesn't rebuild anything).
class AppPalette {
  AppPalette._();

  static AppThemeMode _mode = AppThemeMode.dark;

  static AppThemeMode get mode => _mode;

  static bool get isLight => _mode == AppThemeMode.light;

  /// Only [ThemeModeNotifier] should call this — every other reader goes
  /// through the getters below.
  static void setMode(AppThemeMode mode) {
    _mode = mode;
  }

  static Color get onyx => isLight ? _Light.onyx : _Dark.onyx;
  static Color get surface => isLight ? _Light.surface : _Dark.surface;
  static Color get card => isLight ? _Light.card : _Dark.card;
  static Color get candyBlue => isLight ? _Light.candyBlue : _Dark.candyBlue;
  static Color get steelBlue => isLight ? _Light.steelBlue : _Dark.steelBlue;
  static Color get deepBlue => isLight ? _Light.deepBlue : _Dark.deepBlue;
  static Color get textPrimary =>
      isLight ? _Light.textPrimary : _Dark.textPrimary;
  static Color get textSecondary =>
      isLight ? _Light.textSecondary : _Dark.textSecondary;
  static Color get verified => isLight ? _Light.verified : _Dark.verified;
  static Color get danger => isLight ? _Light.danger : _Dark.danger;
  static Color get gold => isLight ? _Light.gold : _Dark.gold;

  /// The hairline that separates a surface from what is behind it. Was
  /// `glassBorder`, renamed with the rest of the glass vocabulary — it is a
  /// 1px border, and calling it glass implied a translucency the app no
  /// longer has anywhere.
  static Color get hairline => isLight ? _Light.hairline : _Dark.hairline;

  /// Paints [tint] ONTO the card surface instead of letting it show through
  /// to whatever is behind the card.
  ///
  /// # WHY THIS EXISTS
  ///
  /// Nine components asked for a subtle accent by passing a 6–15% alpha
  /// colour as a card's fill. That does not tint a card — it makes the card
  /// 85–94% TRANSPARENT, so `AppBackground`'s photo showed straight through
  /// every one of them. On a light theme, a dark desaturated photo behind a
  /// near-white card is exactly the murky, half-finished "glass" look this
  /// removes.
  ///
  /// Compositing the same colour over the opaque card gives the accent that
  /// was actually intended, at the same values, with nothing showing
  /// through.
  static Color tintedSurface(Color tint) => Color.alphaBlend(tint, card);
}

/// The original values, unchanged — every one of these was previously a
/// public `AppPalette.x` constant directly.
class _Dark {
  _Dark._();

  static const Color onyx = Color(0xFF020202);
  static const Color surface = Color(0xFF0C0F12);
  static const Color card = Color(0xFF14181C);
  static const Color candyBlue = Color(0xFFB2D5E5);
  static const Color steelBlue = Color(0xFF6E93AC);
  static const Color deepBlue = Color(0xFF274050);
  static const Color textPrimary = Color(0xFFEDF2F6);
  static const Color textSecondary = Color(0xFF93A1AC);
  static const Color verified = Color(0xFF4ADE80);
  static const Color danger = Color(0xFFE5484D);
  static const Color gold = Color(0xFFE5B93D);
  static const Color hairline = Color(0x26FFFFFF);
}

/// First-pass light-mode values (Slice G) — background/surface/card/text
/// inverted from the dark palette; candyBlue/steelBlue darkened from their
/// dark-mode pastel values since those read as accent text/icon color
/// throughout the app and the original pale tones have poor contrast on a
/// light background; verified/danger/gold darkened slightly for the same
/// contrast reason.
///
/// The old `glassTint` is GONE, not ported: it existed for a translucent
/// surface treatment the app no longer uses, and its light-mode value was
/// always flagged as a guess rather than a real inversion. `hairline` (was
/// `glassBorder`) survives because a 1px separator is a real thing that both
/// themes need.
class _Light {
  _Light._();

  static const Color onyx = Color(0xFFF7F9FA);
  static const Color surface = Color(0xFFF0F3F5);
  static const Color card = Color(0xFFFFFFFF);
  static const Color candyBlue = Color(0xFF2E6483);
  static const Color steelBlue = Color(0xFF5A7A8C);
  static const Color deepBlue = Color(0xFFD9E7EC);
  static const Color textPrimary = Color(0xFF12181C);
  static const Color textSecondary = Color(0xFF5B6670);
  static const Color verified = Color(0xFF1E9A56);
  static const Color danger = Color(0xFFC7373D);
  static const Color gold = Color(0xFFB68A1E);
  static const Color hairline = Color(0x1F12181C);
}
