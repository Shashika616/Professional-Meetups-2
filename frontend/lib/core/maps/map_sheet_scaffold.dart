import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The "map behind, panel in front" layout every map screen in the app now
/// uses: a map filling the whole area, something floating over its top
/// (usually a search field), and a panel resting on the bottom edge
/// carrying the address and the action.
///
/// # THE ONE THING THIS SOLVES
///
/// The map has to run edge to edge, including underneath the panel, or the
/// panel reads as a box sitting next to a map rather than over it. But the
/// PIN has to sit in the middle of the part you can actually SEE — centred
/// in the full area it would hide behind the panel, which is exactly the
/// bug that makes a picker feel wrong: you drag a place under the pin and
/// the place you picked is somewhere else.
///
/// Both at once, without measuring anything: the map fills the Stack, and
/// a second full-size layer is a Column of [Expanded] plus the panel. The
/// Column gives the panel its natural height and hands the Expanded
/// whatever is left, so centring the pin inside that Expanded puts it in
/// the middle of the visible map for free — no GlobalKey, no post-frame
/// measurement, no frame of wrong placement, and it re-lays out on its own
/// when the panel grows (a long address wrapping, a keyboard opening).
class MapSheetScaffold extends StatelessWidget {
  const MapSheetScaffold({
    super.key,
    required this.map,
    required this.sheet,
    this.topOverlay,
    this.centrePin,
    this.mapActions,
    this.overlay,
  });

  /// The map surface. Fills the whole area, panel included.
  final Widget map;

  /// The panel on the bottom edge. Sized to its own content; use
  /// [MapSheet] for the standard surface.
  final Widget sheet;

  /// Floats over the top of the map, inside the visible area — the search
  /// field on the pickers, nothing on the read-only view.
  final Widget? topOverlay;

  /// Centred in the VISIBLE map, above the panel. Must not take hit tests
  /// or it would eat the drags meant for the map ([MapCentrePin] is
  /// already an IgnorePointer).
  final Widget? centrePin;

  /// Small controls sitting just above the panel, right-aligned — the
  /// recentre button.
  final Widget? mapActions;

  /// Covers everything, panel included. For the search suggestions and
  /// their scrim, which must paint over the map AND the panel.
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Layer 1: the map, edge to edge, continuing behind the panel.
        Positioned.fill(child: map),

        // Layer 2: the geometry. Positioned.fill so the Column gets tight
        // constraints and Expanded has something to divide.
        Positioned.fill(
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    if (centrePin != null) Center(child: centrePin!),
                    if (topOverlay != null)
                      Positioned(
                        top: 12,
                        left: 16,
                        right: 16,
                        child: topOverlay!,
                      ),
                    if (mapActions != null)
                      Positioned(right: 16, bottom: 12, child: mapActions!),
                  ],
                ),
              ),
              sheet,
            ],
          ),
        ),

        // Layer 3: anything that must cover the panel too.
        if (overlay != null) Positioned.fill(child: overlay!),
      ],
    );
  }
}

/// The panel surface: rounded top corners, a grab handle, the card colour,
/// and a shadow that lifts it off the map.
///
/// Matches `AppSheet` (the app's modal bottom sheet) on purpose — handle,
/// 22pt top radius, card background — so a panel that is part of a page
/// and a sheet that was dragged up read as the same kind of surface. The
/// difference is that this one is laid out, not presented: it has no
/// route, cannot be dismissed, and sizes to its content.
class MapSheet extends StatelessWidget {
  const MapSheet({super.key, required this.children, this.handle = true});

  final List<Widget> children;

  /// The grab handle. Shown even though this panel does not drag: it is
  /// what makes the surface read as a sheet rather than a docked bar, and
  /// the app's modal sheets all have one.
  final bool handle;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppPalette.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        boxShadow: [
          BoxShadow(
            color: AppPalette.onyx.withValues(alpha: 0.28),
            blurRadius: 24,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: Padding(
        // The bottom inset is the home indicator or the three-button
        // navigation bar, added here rather than with a SafeArea widget so
        // the shadow and the rounded corners still belong to the sheet.
        //
        // viewPadding, matching every other sheet in this app (AppSheet,
        // the join and schedule-conflict sheets): it is the physical inset
        // and does not collapse when a keyboard is up.
        //
        // Safe inside a SafeArea as well as outside one. A SafeArea reduces
        // BOTH padding and viewPadding to zero for its descendants, so the
        // picker (whose step sits inside the schedule flow's SafeArea)
        // reads zero here and is inset once by that SafeArea, while the
        // location view page — which has no SafeArea — reads the real inset
        // and insets itself. Verified, not assumed: measuring both values
        // inside and outside a SafeArea is the only way to know, and the
        // documentation does not say.
        //
        // All of it is invisible on Android 14 and below, where the app is
        // not edge-to-edge and every inset is zero. Android 15 forces
        // edge-to-edge for apps targeting SDK 35+, which this one does.
        padding: EdgeInsets.fromLTRB(
          20,
          handle ? 10 : 18,
          20,
          16 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (handle) ...[
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppPalette.hairline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
            ],
            ...children,
          ],
        ),
      ),
    );
  }
}

/// A round control that floats on the map — the recentre button.
///
/// White-on-map rather than the app accent: it sits over photography-like
/// tiles whose colour cannot be predicted, and a tinted circle there reads
/// as part of the map instead of as a control over it.
class MapActionButton extends StatelessWidget {
  const MapActionButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.busy = false,
    this.semanticLabel,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final bool busy;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: AppPalette.card,
        shape: const CircleBorder(),
        elevation: 4,
        shadowColor: AppPalette.onyx.withValues(alpha: 0.4),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: busy ? null : onPressed,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: busy
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppPalette.candyBlue,
                      ),
                    )
                  : Icon(icon, size: 21, color: AppPalette.textPrimary),
            ),
          ),
        ),
      ),
    );
  }
}
