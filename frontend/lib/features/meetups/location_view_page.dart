import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:apple_maps_flutter/apple_maps_flutter.dart' as apple_maps;
import 'package:maplibre_gl/maplibre_gl.dart' as maplibre;
import 'package:url_launcher/url_launcher.dart';

import 'package:professional_connections_platform/core/config/app_config.dart';
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
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('LOCATION')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: (lat == null || lng == null)
                ? Center(
                    child: Text(
                      'Location isn\'t available for this meetup.',
                      style: TextStyle(color: AppPalette.textSecondary),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: SizedBox(
                          height: 260,
                          child: _LocationPreviewMap(lat: lat, lng: lng),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        meetup.locationLabel ?? 'Meetup location',
                        style: TextStyle(
                          color: AppPalette.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 20),
                      PrimaryButton(
                        label: 'GET DIRECTIONS',
                        onPressed: () => _getDirections(context),
                      ),
                    ],
                  ),
          ),
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

/// Read-only map preview, platform-split the same way `MapLocationStep`
/// dispatches its own interactive picker (`IosMapLocationStep` /
/// `StadiaMapLocationStep`) — but two small new widgets here rather than
/// reusing the pickers themselves in some "preview mode": the pickers are
/// stateful and own a search controller, debounce timer, and completions
/// list a read-only view has no use for, and retrofitting an
/// optional-everything preview path onto that working, already-tested code
/// would have been a larger, riskier change than mirroring just the "fixed
/// center + overlay pin" rendering they already both use, statically, with
/// every gesture disabled.
class _LocationPreviewMap extends StatelessWidget {
  const _LocationPreviewMap({required this.lat, required this.lng});

  final double lat;
  final double lng;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        defaultTargetPlatform == TargetPlatform.iOS
            ? apple_maps.AppleMap(
                initialCameraPosition: apple_maps.CameraPosition(
                  target: apple_maps.LatLng(lat, lng),
                  zoom: 15,
                ),
                compassEnabled: false,
                rotateGesturesEnabled: false,
                scrollGesturesEnabled: false,
                zoomGesturesEnabled: false,
                pitchGesturesEnabled: false,
                myLocationButtonEnabled: false,
              )
            : maplibre.MapLibreMap(
                styleString:
                    '$_stadiaStyleUrl?api_key=${AppConfig.stadiaMapsApiKey}',
                initialCameraPosition: maplibre.CameraPosition(
                  target: maplibre.LatLng(lat, lng),
                  zoom: 15,
                ),
                compassEnabled: false,
                rotateGesturesEnabled: false,
                scrollGesturesEnabled: false,
                zoomGesturesEnabled: false,
                tiltGesturesEnabled: false,
                myLocationEnabled: false,
              ),
        // Same fixed-center overlay pin as both picker widgets — the
        // preview's camera is centered exactly on (lat, lng), so a static
        // overlay icon at the center is the marker, no annotation/symbol
        // API needed.
        IgnorePointer(
          child: Icon(
            Icons.location_on,
            color: AppPalette.candyBlue,
            size: 36,
            shadows: [
              Shadow(
                color: AppPalette.onyx.withValues(alpha: 0.6),
                blurRadius: 6,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Matches `StadiaMapLocationStep`'s own style — the same visual language,
/// not a second style choice.
const _stadiaStyleUrl =
    'https://tiles.stadiamaps.com/styles/alidade_smooth_dark.json';
