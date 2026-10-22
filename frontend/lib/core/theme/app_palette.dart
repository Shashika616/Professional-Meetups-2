import 'package:flutter/material.dart';

/// The two theme modes this app supports (Slice G) — deliberately just
/// dark/light, not `ThemeMode.system`: [ThemeModeNotifier] in
/// `app_providers.dart` defaults every existing user to dark on first
/// launch of this update, not whatever their OS brightness happens to be.
enum AppThemeMode { dark, light }

/// Every color in this app as a `static` getter, dispatching on
/// [AppPalette.mode].
///
/// # THE 2026-10 REDESIGN RETUNED EVERY VALUE IN HERE
///
/// The values below are sampled from the TieHere screen set
/// (`TieHere All Screens.html`), not nudged from what was here before. Three
/// things actually changed, and they are the reason the app looks different
/// now:
///
///  1. **The ground went blue.** It was a neutral near-black (`#07090C`)
///     with a neutral card on it. It is now a blue-black gradient
///     (`#0A121C` → `#070D15`) with a blue card (`#0F1824`). The mark is a
///     saturated blue/green figure pair, and a neutral grey ground beside it
///     read as a screenshot of some other app with the logo pasted on.
///  2. **The primary button went green.** [solid] is [brandGreen], not
///     [candyBlue]. Blue was doing two jobs at once — "this is a link / an
///     accent" AND "this is the action" — so on a screen with three blue
///     things, none of them was obviously the button. Green is used for
///     exactly one thing, and the eye finds it instantly.
///  3. **Dark cards stopped having borders.** See [hairline].
///
/// The getter *names* are all unchanged, which is what let a redesign of
/// this size land without touching ~700 call sites.
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

  /// The page ground. This is the *bottom* stop of [backgroundGradient] —
  /// read it directly only where a flat fill is wanted (the system nav bar
  /// colour, a full-bleed error screen); page backgrounds should use the
  /// gradient so the top of the screen lifts slightly.
  static Color get onyx => isLight ? _Light.onyx : _Dark.onyx;

  /// The ground as it is actually painted: a near-invisible vertical fade,
  /// lighter at the top.
  ///
  /// It is two stops about 3% apart, which is deliberately almost nothing.
  /// A flat fill made tall scrolling pages feel like a wall; a gradient
  /// anyone can *see* would fight the cards sitting on it. This is the
  /// amount you only notice when you take it away.
  static LinearGradient get backgroundGradient => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: isLight
        ? const [_Light.onyxTop, _Light.onyx]
        : const [_Dark.onyxTop, _Dark.onyx],
  );

  /// The two brand colours, sampled from the TieHere mark itself rather than
  /// eyeballed: the blue and green of the interlocked figures. They are the
  /// same in both themes - a brand colour that shifts with the theme is not a
  /// brand colour - so they sit here rather than in the _Dark/_Light pair.
  static const Color brandBlue = Color(0xFF0075F6);
  static const Color brandGreen = Color(0xFF34C24C);

  /// One step up from [card]: the fill for a control sitting *on* a card
  /// (a filter chip, a square icon tile, a stepper's +/− buttons, an
  /// unselected segment). Both themes move away from the card — dark goes
  /// lighter, light goes darker — so the control reads as a control in
  /// either one.
  static Color get raised => isLight ? _Light.raised : _Dark.raised;

  static Color get surface => isLight ? _Light.surface : _Dark.surface;
  static Color get card => isLight ? _Light.card : _Dark.card;

  /// The accent: links, selected chips, active nav items, field icons.
  /// NOT the primary button — that is [solid]. See the class doc.
  static Color get candyBlue => isLight ? _Light.candyBlue : _Dark.candyBlue;
  static Color get steelBlue => isLight ? _Light.steelBlue : _Dark.steelBlue;
  static Color get deepBlue => isLight ? _Light.deepBlue : _Dark.deepBlue;

  /// The accent at the alpha the design uses for a *tinted surface* —
  /// a selected chip's fill, an informational banner. Composite it with
  /// [tintedSurface] rather than passing it as a fill; see that method.
  static Color get accentTint =>
      candyBlue.withValues(alpha: isLight ? 0.09 : 0.12);

  /// The primary action's fill, and the colour of text sitting on it.
  ///
  /// Green, not blue, and the one colour in the app reserved for a single
  /// meaning: *this is the button*. [solidFg] is near-black on dark (the
  /// green is bright enough that white on it is the lower-contrast choice)
  /// and white on light (where the green is darkened to [_Light.solid] so it
  /// can carry white text at AA).
  static Color get solid => isLight ? _Light.solid : _Dark.solid;
  static Color get solidFg => isLight ? _Light.solidFg : _Dark.solidFg;

  static Color get textPrimary =>
      isLight ? _Light.textPrimary : _Dark.textPrimary;
  static Color get textSecondary =>
      isLight ? _Light.textSecondary : _Dark.textSecondary;

  /// The third text rank, below [textSecondary]: a disabled chip's label,
  /// an inactive nav item, the caption under a stepper. Previously these
  /// all used [textSecondary] and flattened into the body copy around them.
  static Color get textTertiary =>
      isLight ? _Light.textTertiary : _Dark.textTertiary;

  static Color get verified => isLight ? _Light.verified : _Dark.verified;

  /// [verified] FOR TEXT, which is a different colour from [verified] for
  /// fills — for the same reason [dangerOnTint] exists.
  ///
  /// LIGHT MODE NEEDS THIS. The brand green on white measures **2.34:1**,
  /// nowhere near the 4.5:1 AA wants for a 12–13px "Verified" caption, and
  /// it was being used as body text in ~20 places. #157739 measures 5.63:1
  /// on the card, 4.82:1 on [raised] and 5.04:1 on a green-tinted card —
  /// the three grounds it actually lands on.
  ///
  /// DARK MODE DOES NOT, strictly: [verified] on the dark card is already
  /// 7.62:1. #5ED47A (9.50:1) is here because the design uses a lighter
  /// green for text than for fills, and because a single `verifiedText`
  /// that silently fell back to `verified` on one theme would be a trap for
  /// whoever retunes this next.
  ///
  /// Use [verified] for the tick glyph, a chip fill, a progress bar. Use
  /// this the moment it becomes a word someone has to read.
  static Color get verifiedText =>
      isLight ? _Light.verifiedText : _Dark.verifiedText;

  static Color get danger => isLight ? _Light.danger : _Dark.danger;

  /// The SOS control's fill — a deeper, flatter red than [danger], which is
  /// an *alert* colour. This one is a surface someone presses on purpose.
  static Color get sos => const Color(0xFFC8323A);

  /// [danger] for TEXT AND ICONS SITTING ON A DANGER-TINTED SURFACE.
  ///
  /// The SOS control is danger-coloured text on a card tinted with danger at
  /// 12%. Measured against that background, [danger] gives **3.86:1** —
  /// below the 4.5:1 WCAG AA needs for 13px text. Light mode was marginal
  /// too, at 4.35:1. On the control someone uses when they feel unsafe,
  /// "mostly legible" is not a standard worth defending.
  ///
  /// The obvious alternative does not work, which is worth recording so
  /// nobody tries it: filling the card with solid [danger] and using white
  /// text measures **3.91:1** and fails as well.
  ///
  /// `test/danger_contrast_test.dart` recomputes both ratios and fails if
  /// either drops below 4.5:1.
  static Color get dangerOnTint =>
      isLight ? _Light.dangerOnTint : _Dark.dangerOnTint;

  /// A cancelled meetup's state colour: the card edge, chip and headline
  /// for a meetup the host called off. Softer than [danger] on purpose —
  /// this marks a state the user is looking at, not an error they caused.
  static Color get cancelled => isLight ? _Light.cancelled : _Dark.cancelled;
  static Color get gold => isLight ? _Light.gold : _Dark.gold;

  /// The unfilled remainder of a progress bar, slider or step indicator,
  /// and the divider inside a card. Distinct from [hairline], which
  /// separates a surface from the page; this one lives *within* a surface.
  static Color get track => isLight ? _Light.track : _Dark.track;

  /// The floating bottom bar's fill. Translucent in both themes because the
  /// bar sits *over* scrolling content — the page sliding under it is the
  /// cue that it is floating rather than part of the page.
  static Color get navSurface => isLight ? _Light.navSurface : _Dark.navSurface;

  /// The hairline that separates a surface from what is behind it.
  ///
  /// # IT IS NEARLY GONE IN DARK MODE NOW
  ///
  /// Every card used to draw a 1px `0x22FFFFFF` outline in both themes. On
  /// the new blue-black ground that outline is the loudest thing on the
  /// screen: a list of eight cards became eight grey rectangles, and the
  /// eye read the borders instead of the content.
  ///
  /// Dark cards now separate by *fill* — `#0F1824` on a `#070D15` ground is
  /// a clear step — plus the 1px top inset highlight [FlatCard] draws, which
  /// is how a lit surface actually reads. This value drops to `0x14FFFFFF`
  /// for the handful of places that still want an explicit edge (a divider,
  /// an outlined button). Light mode is unchanged: a white card on a near-
  /// white ground genuinely needs the line, and gets a shadow as well.
  static Color get hairline => isLight ? _Light.hairline : _Dark.hairline;

  /// Paints [tint] ONTO the card surface instead of letting it show through
  /// to whatever is behind the card.
  ///
  /// Nine components asked for a subtle accent by passing a 6–15% alpha
  /// colour as a card's fill. That does not tint a card — it makes the card
  /// 85–94% TRANSPARENT. Compositing the same colour over the opaque card
  /// gives the accent that was actually intended, at the same values, with
  /// nothing showing through.
  static Color tintedSurface(Color tint) => Color.alphaBlend(tint, card);

  /// [tintedSurface] for a tint sitting on [raised] instead of on a card —
  /// a selected filter chip, whose unselected state is already [raised].
  static Color tintedRaised(Color tint) => Color.alphaBlend(tint, raised);
}

/// Dark mode is a blue-black, not a neutral one: the ground, the card and
/// the raised surface are three steps of the same blue ramp, so a chip on a
/// card on the page reads as three heights of one material rather than
/// three unrelated greys.
class _Dark {
  _Dark._();

  static const Color onyxTop = Color(0xFF0A121C);
  static const Color onyx = Color(0xFF070D15);
  static const Color surface = Color(0xFF101B29);
  static const Color card = Color(0xFF0F1824);
  static const Color raised = Color(0xFF172536);
  static const Color candyBlue = Color(0xFF8EC5EE);
  static const Color steelBlue = Color(0xFF5FA8DC);
  static const Color deepBlue = Color(0xFF274050);
  static const Color solid = AppPalette.brandGreen;
  static const Color solidFg = Color(0xFF04140A);
  static const Color textPrimary = Color(0xFFF1F5F9);
  static const Color textSecondary = Color(0xFFA9B6C4);
  static const Color textTertiary = Color(0xFF8F9EAF);
  static const Color verified = AppPalette.brandGreen;
  static const Color verifiedText = Color(0xFF5ED47A);
  static const Color danger = Color(0xFFE5484D);
  // 13% toward white: 4.52:1 on the 12%-danger-tinted card. See
  // AppPalette.dangerOnTint.
  static const Color dangerOnTint = Color(0xFFE86064);
  static const Color cancelled = Color(0xFFE8747A);
  static const Color gold = Color(0xFFE5B93D);
  static const Color track = Color(0xFF1B2A3C);
  static const Color navSurface = Color(0xBD101B29);
  static const Color hairline = Color(0x14FFFFFF);
}

/// Light mode is the same blue ramp read from the other end: a white card,
/// a faintly blue raised surface, and a page ground just cool enough that
/// the white card has somewhere to sit.
class _Light {
  _Light._();

  static const Color onyxTop = Color(0xFFF7F9FC);
  static const Color onyx = Color(0xFFF0F4F8);
  static const Color surface = Color(0xFFE8EEF5);
  static const Color card = Color(0xFFFFFFFF);
  static const Color raised = Color(0xFFE8EEF5);
  static const Color candyBlue = Color(0xFF1F6FA8);
  static const Color steelBlue = Color(0xFF1F6FA8);
  static const Color deepBlue = Color(0xFFD9E7EC);
  static const Color solid = Color(0xFF17803D);
  static const Color solidFg = Color(0xFFFFFFFF);
  static const Color textPrimary = Color(0xFF131A23);
  static const Color textSecondary = Color(0xFF4F5C6B);
  static const Color textTertiary = Color(0xFF5A6677);
  static const Color verified = Color(0xFF2DAA45);
  static const Color verifiedText = Color(0xFF157739);
  static const Color danger = Color(0xFFC7373D);
  // 3% darker: 4.58:1 on the 12%-danger-tinted card. See
  // AppPalette.dangerOnTint.
  static const Color dangerOnTint = Color(0xFFC1353B);
  static const Color cancelled = Color(0xFFD9666C);
  // #B68A1E (the design's light gold) measures 3.16:1 on white — it is a
  // RATING, i.e. 12px text, in every place it is used. Darkened until it
  // passes on both grounds it lands on: 5.48:1 on the card, 4.69:1 on
  // [raised].
  static const Color gold = Color(0xFF856413);
  static const Color track = Color(0xFFDFE7EF);
  static const Color navSurface = Color(0xC7FFFFFF);
  static const Color hairline = Color(0x1F12181C);
}
