import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The app's icon set: thin stroked outlines, drawn from the TieHere screen
/// set's own SVG paths.
///
/// # WHY NOT MATERIAL ICONS
///
/// Material's glyphs are a *filled* family with an `_outlined` sibling that
/// is drawn at a different optical weight, and coverage between the two is
/// uneven — so a screen built from them ends up mixing a solid house, a
/// hairline shield and a medium-weight calendar, and reads as three icon
/// sets sharing a toolbar. The redesign specifies one weight everywhere:
/// `fill: none`, `stroke-width: 1.6`, round caps and joins, on a 24×24 box.
/// That is a property of the drawing, not of a font, so it comes from
/// vector paths.
///
/// These paths are the screen set's, copied rather than redrawn, so the app
/// and the design cannot drift apart.
///
/// # THE STROKE DOES NOT SCALE WITH THE ICON
///
/// [AppIcon] renders at the requested [size] but keeps the 24-unit viewBox,
/// so a 32px icon has a *proportionally thinner* stroke than a 16px one —
/// which is the same thing that happens to a font glyph and is what keeps a
/// row of mixed-size icons looking like one family. If you need a heavier
/// line for a large standalone icon, pass [strokeWidth]; do not scale the
/// whole thing up and expect the line to hold.
class AppIcons {
  AppIcons._();

  // Navigation
  static const String home =
      '<path d="M4 11l8-6 8 6v8a1 1 0 0 1-1 1h-4v-5h-6v5H5a1 1 0 0 1-1-1z"/>';
  static const String events =
      '<rect x="4" y="5" width="16" height="15" rx="3"/>'
      '<path d="M8 3v4M16 3v4M4 10h16"/>';
  static const String safety =
      '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/>';
  static const String profile =
      '<circle cx="12" cy="8" r="3.5"/>'
      '<path d="M5 20c1-4 4-6 7-6s6 2 7 6"/>';

  // Chrome
  static const String back = '<path d="M15 6l-6 6 6 6"/>';
  static const String forward = '<path d="M9 6l6 6-6 6"/>';
  static const String chevronDown = '<path d="M6 9l6 6 6-6"/>';
  static const String bell =
      '<path d="M6 17h12l-1.5-2V11a4.5 4.5 0 0 0-9 0v4zM10 20h4"/>';
  static const String close = '<path d="M6 6l12 12M18 6L6 18"/>';
  static const String plus = '<path d="M12 5v14M5 12h14"/>';
  static const String check = '<path d="M5 12.5l4.5 4.5L19 7.5"/>';
  static const String grid =
      '<rect x="4" y="4" width="7" height="7" rx="1.5"/>'
      '<rect x="13" y="4" width="7" height="7" rx="1.5"/>'
      '<rect x="4" y="13" width="7" height="7" rx="1.5"/>'
      '<rect x="13" y="13" width="7" height="7" rx="1.5"/>';

  // Status / meaning
  static const String clock =
      '<circle cx="12" cy="12" r="8.5"/><path d="M12 7v5l3 2"/>';
  static const String info =
      '<circle cx="12" cy="12" r="8.5"/><path d="M12 11v5M12 8v.5"/>';
  static const String warning =
      '<path d="M12 3l9 16H3z"/><path d="M12 10v4M12 17v.5"/>';
  static const String star =
      '<path d="M12 4l2.4 5 5.4.6-4 3.7 1.1 5.4L12 16l-4.9 2.7L8.2 13.3 4.2 9.6 9.6 9z"/>';
  static const String lock =
      '<rect x="5" y="11" width="14" height="9" rx="2.5"/>'
      '<path d="M8 11V8a4 4 0 0 1 8 0v3"/>';
  static const String bulb =
      '<path d="M9 18h6M10 21h4M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2.1h5c0-.9.4-1.6 1-2.1A6 6 0 0 0 12 3z"/>';

  // Verification / identity
  static const String phone =
      '<rect x="7" y="3" width="10" height="18" rx="2.5"/>'
      '<path d="M11 18h2"/>';
  static const String mail =
      '<rect x="3.5" y="6" width="17" height="12" rx="2.5"/>'
      '<path d="M4 8l8 5 8-5"/>';
  static const String link =
      '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1'
      'M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>';
  static const String idCard =
      '<rect x="3.5" y="5" width="17" height="14" rx="2.5"/>'
      '<circle cx="9" cy="11" r="2"/>'
      '<path d="M14 10h4M14 14h3M6 16c.7-1.5 2-2 3-2s2.3.5 3 2"/>';

  // Place / meetup
  static const String pin =
      '<path d="M12 21s7-6.2 7-11.5A7 7 0 0 0 5 9.5C5 14.8 12 21 12 21z"/>'
      '<circle cx="12" cy="9.5" r="2.5"/>';
  static const String directions = '<path d="M4 12l16-8-8 16-2-6z"/>';
  static const String people =
      '<circle cx="9" cy="9" r="3"/><circle cx="17" cy="10" r="2.4"/>'
      '<path d="M3.5 19c.6-3 3-5 5.5-5s4.9 2 5.5 5M15.5 14.5c2.5-.5 4.5 1 5 4"/>';
  static const String requests =
      '<circle cx="9" cy="9" r="3"/>'
      '<path d="M3.5 19c.6-3 3-5 5.5-5s4.9 2 5.5 5M16 6.5a3 3 0 0 1 0 5.5'
      'M18 14.5c1.7.6 2.7 2 3 4.5"/>';
  static const String chat =
      '<path d="M4 6a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-7l-5 4v-4H6a2 2 0 0 1-2-2z"/>';
  static const String coffee =
      '<path d="M4 8h12v6a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4z"/>'
      '<path d="M16 9h2.5a2.5 2.5 0 0 1 0 5H16M4 21h12"/>';
  static const String meal =
      '<path d="M6 3v8a2 2 0 0 0 4 0V3M8 11v10"/>'
      '<path d="M17 3c-1.5 1.5-2 3-2 5s.5 2.5 2 2.5V21"/>';
  static const String mentorship =
      '<path d="M12 4l9 4-9 4-9-4z"/><path d="M6.5 10v4.5c0 1.4 2.5 2.5 5.5 2.5s5.5-1.1 5.5-2.5V10"/>';
  static const String outing =
      '<circle cx="12" cy="12" r="8.5"/>'
      '<path d="M3.5 12h17M12 3.5c2.2 2.4 3.4 5.4 3.4 8.5s-1.2 6.1-3.4 8.5c-2.2-2.4-3.4-5.4-3.4-8.5S9.8 5.9 12 3.5z"/>';

  // Settings / account
  static const String shield = safety;
  static const String signOut =
      '<path d="M14 5h4a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1h-4M10 8l-4 4 4 4M6 12h10"/>';
  static const String trash = '<path d="M5 7h14M9 7V4h6v3M7 7l1 13h8l1-13"/>';
  static const String premium =
      '<path d="M4 18l1.5-9 4.5 4 2-6 2 6 4.5-4L20 18z"/>';
  static const String appearance =
      '<path d="M20 14A8 8 0 0 1 10 4a8 8 0 1 0 10 10z"/>';
  static const String work =
      '<rect x="3.5" y="7" width="17" height="12" rx="2.5"/>'
      '<path d="M9 7V5.5A1.5 1.5 0 0 1 10.5 4h3A1.5 1.5 0 0 1 15 5.5V7"/>';
  static const String search =
      '<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4 4"/>';
  static const String edit = '<path d="M4 20h4L19 9a2.1 2.1 0 0 0-3-3L5 17z"/>';

  // ---------------------------------------------------------------------
  // Second wave: the glyphs the rest of the app was still taking from the
  // Material font. Same construction as everything above — a 24-unit box,
  // no fill, one stroke weight — so a screen that mixes them reads as one
  // set rather than two.
  // ---------------------------------------------------------------------

  static const String checkCircle =
      '<circle cx="12" cy="12" r="8.5"/><path d="M8.4 12.2l2.5 2.5 4.7-5"/>';
  static const String xCircle =
      '<circle cx="12" cy="12" r="8.5"/>'
      '<path d="M9.3 9.3l5.4 5.4M14.7 9.3l-5.4 5.4"/>';
  static const String plusCircle =
      '<circle cx="12" cy="12" r="8.5"/>'
      '<path d="M12 8.3v7.4M8.3 12h7.4"/>';
  static const String minus = '<path d="M6 12h12"/>';

  static const String arrowRight =
      '<path d="M4.5 12h14M13 6.5l5.5 5.5-5.5 5.5"/>';
  static const String arrowLeft =
      '<path d="M19.5 12h-14M11 6.5L5.5 12l5.5 5.5"/>';

  static const String explore =
      '<circle cx="12" cy="12" r="8.5"/><path d="M15.2 8.8l-2 4.4-4.4 2 2-4.4z"/>';
  static const String map =
      '<path d="M9.3 4L4 6v14l5.3-2 5.4 2 5.3-2V4l-5.3 2z"/>'
      '<path d="M9.3 4v14M14.7 6v14"/>';
  static const String locate =
      '<circle cx="12" cy="12" r="3.2"/><circle cx="12" cy="12" r="7.5"/>'
      '<path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2"/>';

  static const String undo =
      '<path d="M8.5 7L4.5 11l4 4"/>'
      '<path d="M4.5 11h9a5 5 0 0 1 0 10h-2.5"/>';
  static const String refresh =
      '<path d="M19.5 12a7.5 7.5 0 1 1-2.2-5.3"/><path d="M19.5 4.5V9H15"/>';
  static const String history =
      '<path d="M4.5 12a7.5 7.5 0 1 0 2.2-5.3"/><path d="M4.5 4.5V9H9"/>'
      '<path d="M12 8v4.3l2.8 1.7"/>';

  static const String person =
      '<circle cx="12" cy="8" r="3.6"/>'
      '<path d="M5 20c.6-3.8 3.5-6 7-6s6.4 2.2 7 6"/>';
  static const String personAdd =
      '<circle cx="10" cy="8" r="3.5"/>'
      '<path d="M3.5 19.5c.4-3.4 3-5.5 6.5-5.5 1.1 0 2.2.2 3.1.6"/>'
      '<path d="M17.5 14.5v6M14.5 17.5h6"/>';
  static const String personRemove =
      '<circle cx="10" cy="8" r="3.5"/>'
      '<path d="M3.5 19.5c.4-3.4 3-5.5 6.5-5.5 1.1 0 2.2.2 3.1.6"/>'
      '<path d="M14.5 17.5h6"/>';

  static const String hourglass =
      '<path d="M7.5 3.5h9M7.5 20.5h9"/>'
      '<path d="M7.5 3.5v3c0 2 2.3 3.4 4.5 5.5 2.2-2.1 4.5-3.5 4.5-5.5v-3'
      'M7.5 20.5v-3c0-2 2.3-3.4 4.5-5.5 2.2 2.1 4.5 3.5 4.5 5.5v3"/>';

  static const String calendar =
      '<rect x="3.5" y="5" width="17" height="15.5" rx="2.5"/>'
      '<path d="M8 3v4M16 3v4M3.5 10h17"/>';
  static const String calendarCheck =
      '$calendar<path d="M9.3 14.8l2 2 3.4-3.6"/>';
  static const String calendarX = '$calendar<path d="M10 14l4 4M14 14l-4 4"/>';

  static const String share =
      '<path d="M12 15.5V4"/><path d="M8.5 7.5L12 4l3.5 3.5"/>'
      '<path d="M6 12.5V19a1.5 1.5 0 0 0 1.5 1.5h9A1.5 1.5 0 0 0 18 19v-6.5"/>';
  static const String broadcast =
      '<circle cx="12" cy="12" r="2.4"/>'
      '<path d="M8 8a5.6 5.6 0 0 0 0 8M16 16a5.6 5.6 0 0 0 0-8"/>'
      '<path d="M5.2 5.2a9.6 9.6 0 0 0 0 13.6M18.8 18.8a9.6 9.6 0 0 0 0-13.6"/>';

  static const String building =
      '<rect x="4.5" y="4" width="15" height="16.5" rx="2"/>'
      '<path d="M9 8h2M13 8h2M9 12h2M13 12h2M10.5 20.5v-4h3v4"/>';
  static const String car =
      '<path d="M3.5 15.5v-3l1.8-4.3A2 2 0 0 1 7.1 7h9.8a2 2 0 0 1 1.8 1.2'
      'l1.8 4.3v3a1 1 0 0 1-1 1h-15a1 1 0 0 1-1-1z"/>'
      '<path d="M6 16.5v2M18 16.5v2"/>'
      '<circle cx="7.5" cy="12.3" r="1"/><circle cx="16.5" cy="12.3" r="1"/>';

  static const String settings =
      '<circle cx="12" cy="12" r="3.2"/>'
      '<path d="M12 2.5v2.6M12 18.9v2.6M4.2 7l2.3 1.3M17.5 15.7l2.3 1.3'
      'M4.2 17l2.3-1.3M17.5 8.3l2.3-1.3"/>';
  static const String filter =
      '<path d="M4 7h9M19 7h1M4 17h3M13 17h7"/>'
      '<circle cx="16" cy="7" r="2.4"/><circle cx="10" cy="17" r="2.4"/>';
  static const String eye =
      '<path d="M2.5 12S6 5.8 12 5.8 21.5 12 21.5 12 18 18.2 12 18.2 2.5 12 2.5 12z"/>'
      '<circle cx="12" cy="12" r="3"/>';

  static const String thumbUp =
      '<path d="M7 10.5v9H4.6a1 1 0 0 1-1-1v-7a1 1 0 0 1 1-1z"/>'
      '<path d="M7 10.5l4-7a2 2 0 0 1 3 1.8V9h4.6a1.8 1.8 0 0 1 1.7 2.3'
      'l-1.6 6a1.8 1.8 0 0 1-1.7 1.2H7z"/>';
  static const String thumbDown =
      '<path d="M7 13.5v-9H4.6a1 1 0 0 0-1 1v7a1 1 0 0 0 1 1z"/>'
      '<path d="M7 13.5l4 7a2 2 0 0 0 3-1.8V15h4.6a1.8 1.8 0 0 0 1.7-2.3'
      'l-1.6-6A1.8 1.8 0 0 0 17 5.5H7z"/>';
  static const String heart =
      '<path d="M12 20s-7.5-4.7-7.5-9.6A4.4 4.4 0 0 1 12 7.6a4.4 4.4 0 0 1 '
      '7.5 2.8C19.5 15.3 12 20 12 20z"/>';
  static const String celebration =
      '<path d="M3.5 20.5l4.8-12 7.2 7.2z"/>'
      '<path d="M14 4.5v2M19.5 10h-2M17.8 6.2l-1.4 1.4"/>';

  static const String cloudOff =
      '<path d="M4 4l16 16"/>'
      '<path d="M8.6 7.3A5.5 5.5 0 0 1 17.8 10.6 3.8 3.8 0 0 1 16.7 18H9"/>'
      '<path d="M6.8 10.4A3.8 3.8 0 0 0 7.2 18"/>';
  static const String verifiedBadge =
      '<path d="M12 3l2 1.8 2.7-.3 1 2.5 2.4 1.2-.7 2.6.7 2.6-2.4 1.2-1 2.5'
      '-2.7-.3L12 21l-2-1.8-2.7.3-1-2.5-2.4-1.2.7-2.6-.7-2.6 2.4-1.2 1-2.5'
      '2.7.3z"/><path d="M9.3 12.2l1.9 1.9 3.5-3.7"/>';
  static const String support =
      '<path d="M4.5 14.5v-2.5a7.5 7.5 0 0 1 15 0v2.5"/>'
      '<path d="M4.5 13.5h1.6a1 1 0 0 1 1 1v3.2a1 1 0 0 1-1 1H5.5'
      'a1 1 0 0 1-1-1z"/>'
      '<path d="M19.5 13.5h-1.6a1 1 0 0 0-1 1v3.2a1 1 0 0 0 1 1h.6'
      'a1 1 0 0 0 1-1z"/>';
  static const String atSign =
      '<circle cx="12" cy="12" r="3.5"/>'
      '<path d="M15.5 12v1.8a2.4 2.4 0 0 0 4.8 0V12a8.3 8.3 0 1 0-3.3 6.6"/>';

  static const String checkbox =
      '<rect x="3.5" y="3.5" width="17" height="17" rx="4.5"/>';
  static const String checkboxChecked =
      '$checkbox<path d="M8.2 12.2l2.6 2.6 5-5.2"/>';
}

/// Renders one of [AppIcons]' paths at [size] in [color].
class AppIcon extends StatelessWidget {
  const AppIcon(
    this.path, {
    super.key,
    this.size = 20,
    this.color,
    this.strokeWidth = 1.6,
  });

  /// One of the `AppIcons.*` constants.
  final String path;
  final double size;
  final Color? color;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? DefaultTextStyle.of(context).style.color!;
    // `stroke="currentColor"` plus a colorFilter would double-paint the
    // tint; the colour is written into the markup so flutter_svg's string
    // cache keys on it and each (icon, colour) pair is parsed once.
    final hex = _hex(resolved);
    final svg =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
        'fill="none" stroke="$hex" stroke-width="$strokeWidth" '
        'stroke-linecap="round" stroke-linejoin="round">$path</svg>';
    return SizedBox(
      width: size,
      height: size,
      child: SvgPicture.string(
        svg,
        width: size,
        height: size,
        // Opacity is carried separately: an alpha in the hex would be
        // dropped by some SVG parsers.
        colorFilter: resolved.a < 1
            ? ColorFilter.mode(resolved, BlendMode.srcIn)
            : null,
      ),
    );
  }

  static String _hex(Color c) =>
      '#'
      '${(c.r * 255).round().toRadixString(16).padLeft(2, '0')}'
      '${(c.g * 255).round().toRadixString(16).padLeft(2, '0')}'
      '${(c.b * 255).round().toRadixString(16).padLeft(2, '0')}';
}
