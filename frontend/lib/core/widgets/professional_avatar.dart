import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The user's profile picture. Shows initials until a real photo URL
/// arrives from the backend. The brand mark is a separate widget: [AppIcon].
///
/// # THE RING IS BLUE, AND ONLY THE DOT IS GREEN
///
/// [ring] draws a 2.5px band around the avatar, separated from it by a
/// card-coloured gap. It is opt-in and only two screens take it — the Home
/// header and the profile header — because it is a flourish, and a
/// flourish repeated on every avatar in a participant list is wallpaper.
///
/// It used to be a `brandBlue → brandGreen` gradient, which put green in
/// two places that mean different things: the band, where it meant
/// nothing, and the presence dot beside it, where it means "signed in".
/// A ring that fades into the same green as the dot it sits behind makes
/// the dot harder to find, and green elsewhere in this app is reserved
/// (the primary action, a verified badge). The band is now flat
/// [AppPalette.candyBlue] and the dot is the only green on the avatar.
///
/// The fill underneath went from a `deepBlue → steelBlue` gradient with a
/// blue outline to a flat [AppPalette.raised]: a gradient inside a
/// gradient ring is mud, and the initials need a calm ground to be read
/// against at 12px in a list row.
class ProfessionalAvatar extends StatelessWidget {
  const ProfessionalAvatar({
    super.key,
    this.name,
    this.imageUrl,
    this.size = 44,
    this.ring = false,
    this.showPresenceDot = false,
  });

  final String? name;
  final String? imageUrl;
  final double size;

  /// Draws the brand gradient band around the avatar. See the class doc.
  final bool ring;

  /// The small green dot on the lower-trailing edge. Only meaningful
  /// beside [ring], and only on the viewer's OWN avatar — it says "this is
  /// you, you are signed in", not "this person is online"; there is no
  /// presence system behind it to mean the latter.
  final bool showPresenceDot;

  /// Conservative upper bound for device pixel ratio, used to size the
  /// network image's decode cache (see the `cacheWidth`/`cacheHeight`
  /// comment in [build]).
  static const double _maxDevicePixelRatio = 3;

  String get _initials {
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return 'PC';
    final parts = trimmed.split(RegExp(r'\s+'));
    final first = parts.first.isNotEmpty ? parts.first[0].toUpperCase() : '';
    final last = parts.length > 1 ? parts.last[0].toUpperCase() : '';
    return '$first$last';
  }

  @override
  Widget build(BuildContext context) {
    final avatar = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppPalette.raised,
      ),
      child: ClipOval(
        child: imageUrl != null
            ? Image.network(
                imageUrl!,
                fit: BoxFit.cover,
                // 2026-08-31 round-3 hardening, Fix 3: without
                // cacheWidth/cacheHeight, Image.network decodes and caches
                // a photo at its full source resolution even though it
                // only ever renders at [size] logical pixels here — wasteful
                // memory per unique avatar URL, more so with Fix 1's now-
                // longer scrollable lists. `_maxDevicePixelRatio` is a
                // fixed conservative upper bound rather than the actual
                // device's ratio (queryable via MediaQuery, but not worth
                // the per-build context dependency for a cache-size hint).
                cacheWidth: (size * _maxDevicePixelRatio).round(),
                cacheHeight: (size * _maxDevicePixelRatio).round(),
                errorBuilder: (context, error, stackTrace) => _initialsWidget(),
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : _initialsWidget(),
              )
            : _initialsWidget(),
      ),
    );

    if (!ring) return avatar;

    // The gap between band and photo is painted as a border ON the avatar
    // rather than as padding on the band, so the band's own thickness
    // stays exactly 2.5 regardless of [size].
    final ringed = Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppPalette.candyBlue,
      ),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: AppPalette.card, width: 2.5),
        ),
        child: avatar,
      ),
    );

    if (!showPresenceDot) return ringed;

    final double dot = (size * 0.25).clamp(9.0, 14.0);

    // The dot sits ON the rim, at the lower-trailing 45 degrees.
    //
    // `right: 0, bottom: 0` put it at the corner of the bounding BOX, and
    // a circle only touches its box at the four midpoints — so the dot
    // floated diagonally off the edge. Unnoticeable on a 44px list avatar,
    // obvious on the 104px one the profile header uses, which is where it
    // was spotted. The inset below is the gap between the box corner and
    // the circle at 45 degrees, less half the dot so its centre lands on
    // the rim rather than its edge.
    final double outer = size + 5; // the band adds 2.5 on each side
    final double inset = (outer / 2) * (1 - math.sqrt1_2) - dot / 2;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        ringed,
        Positioned(
          right: inset,
          bottom: inset,
          child: Container(
            width: dot,
            height: dot,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppPalette.verified,
              border: Border.all(color: AppPalette.card, width: 2),
            ),
          ),
        ),
      ],
    );
  }

  Widget _initialsWidget() {
    return Center(
      child: Text(
        _initials,
        style: TextStyle(
          color: AppPalette.candyBlue,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.36,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
