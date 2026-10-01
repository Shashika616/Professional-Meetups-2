import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:url_launcher/url_launcher.dart';

import 'package:professional_connections_platform/core/maps/map_canvas.dart';
import 'package:professional_connections_platform/core/maps/map_sheet_scaffold.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

/// ADR-029 (round-8 hardening) — a read-only "View Location" preview plus
/// a "Get Directions" deep link. Gated by exactly the same
/// [Meetup.lockedForViewer] check ADR-028 already applies everywhere else
/// (no new gating concept, no participation check). No in-app routing —
/// Get Directions only ever opens the user's own installed maps app via
/// [launchUrl].
class LocationViewPage extends StatelessWidget {
  const LocationViewPage({super.key, required this.meetup});

  final Meetup meetup;

  /// The single entry point every "View Location" tap should call — every
  /// caller uses this instead of duplicating the gate.
  ///
  /// # THE GATE HERE HAS MOVED TWICE; THIS IS THE THIRD AND NARROWEST FORM
  ///
  /// Originally it keyed on [Meetup.lockedForViewer], which was right when
  /// redaction nulled the location outright: there was nothing to show.
  /// ADR-002 § 5 then made the location visible to guests and I removed the
  /// gate entirely, on the reasoning that blocking a page for data the
  /// server deliberately sends is a client-side-only gate — the pattern
  /// ADR-028 rejects.
  ///
  /// That reasoning was right about the LABEL and wrong about this PAGE.
  /// The card's coarse label ("Colombo Fort Cafe") is what ADR-002 § 5
  /// intends a guest to see — enough to know meetups are happening nearby.
  /// This page is a different thing: an interactive map plus exact
  /// lat/lng plus a directions deep link. Combined with guest signup
  /// requiring no identity verification at all, an ungated version is a
  /// scriptable way to harvest precise meetup coordinates at scale, which
  /// is a materially different exposure from a place name on a card.
  ///
  /// So the gate is back, keyed on [viewerTrustLevel] rather than
  /// `lockedForViewer`. Those happen to coincide today (after ADR-002 § 6
  /// only guests are locked), but they answer different questions, and this
  /// one is explicitly "has this account done anything at all to identify
  /// itself". Level 1+ opens unconditionally, exactly as today.
  ///
  /// This is UX enforcement, not the security boundary — the coordinates
  /// are in the response the client already holds. It raises the cost of
  /// bulk collection from "call an endpoint" to "modify the app", which is
  /// the honest description of what a client-side gate buys. The real fix
  /// if this is ever attacked is server-side coarsening for Level 0, which
  /// would be an ADR-002 amendment rather than a change here.
  static void open(
    BuildContext context,
    Meetup meetup, {
    required int viewerTrustLevel,
  }) {
    if (viewerTrustLevel < 1) {
      showSnack(
        context,
        'Sign up to see exactly where this meetup is happening.',
        type: ToastType.locked,
      );
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const VerificationChecklistPage()),
      );
      return;
    }
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => LocationViewPage(meetup: meetup)));
  }

  Future<void> _getDirections(BuildContext context) async {
    final lat = meetup.locationLat;
    final lng = meetup.locationLng;
    if (lat == null || lng == null) return;
    // Platform-split deep link, same split as _LocationPreviewMap below —
    // iOS gets Apple Maps (maps.apple.com is a universal link, always
    // installed, opens directly in the app), everyone else gets Google
    // Maps' directions URL. Deep-linking an iOS user into Google Maps
    // instead of their own platform's map app was a real bug, not a
    // deliberate choice.
    final uri = defaultTargetPlatform == TargetPlatform.iOS
        ? Uri.parse('https://maps.apple.com/?daddr=$lat,$lng&dirflg=d')
        : Uri.parse(
            'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng',
          );
    final launch = debugLaunchUrlOverride ?? launchUrl;
    final launched = await launch(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      showSnack(context, 'Could not open a maps app.', type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Defense in depth only — a locked meetup never reaches this page
    // (open() redirects it), so lat/lng/label are expected to always be
    // real here. Handled anyway rather than force-unwrapping into a crash
    // if that stops being true (e.g. a future deep link).
    final lat = meetup.locationLat;
    final lng = meetup.locationLng;
    if (lat == null || lng == null) {
      // Nothing to draw a map of, so this one keeps the ordinary page
      // chrome rather than floating a back button over an empty surface.
      return AppBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(title: const Text('LOCATION')),
          body: Center(
            child: Text(
              'Location isn\'t available for this meetup.',
              style: TextStyle(color: AppPalette.textSecondary),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      // The map is the page, so the ground behind it is the map's own, not
      // the app's photographic background.
      backgroundColor: AppPalette.onyx,
      body: MapSheetScaffold(
        // Still read-only, and still every gesture off: this page shows
        // where one meetup is, and ADR-029 chose a picture over a map you
        // can wander away from. Full-bleed changes how big that picture
        // is, not what it does.
        map: MapCanvas(
          initialCentre: MapPoint(lat, lng),
          initialZoom: 16,
          interactive: false,
        ),
        centrePin: const MapCentrePin(),
        topOverlay: const _FloatingBackButton(),
        sheet: MapSheet(
          children: [
            Text(
              'MEETUP LOCATION',
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.place_outlined,
                  size: 18,
                  color: AppPalette.candyBlue,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    meetup.locationLabel ?? 'Meetup location',
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            PrimaryButton(
              label: 'GET DIRECTIONS',
              icon: Icons.directions_rounded,
              onPressed: () => _getDirections(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// A back affordance that works over a map.
///
/// This page has no AppBar any more — one would either cut the map off at
/// a hard edge or float a title over tiles whose colour cannot be
/// predicted. A circular button carrying the card colour reads on anything
/// underneath it, which is the same reason [MapActionButton] looks the way
/// it does.
class _FloatingBackButton extends StatelessWidget {
  const _FloatingBackButton();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Align(
        alignment: Alignment.centerLeft,
        child: MapActionButton(
          icon: Icons.arrow_back_rounded,
          semanticLabel: 'Back',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }
}

/// Test-only override for the actual `launchUrl` call — same optional-
/// override pattern `StadiaMapLocationStep`'s injectable `http.Client` and
/// `debugStadiaApiKeyOverride` already use in this codebase, applied here
/// so a widget test can assert on the built URL without a real platform
/// channel/installed maps app. Real code must never set this.
@visibleForTesting
Future<bool> Function(Uri url, {LaunchMode mode})? debugLaunchUrlOverride;
