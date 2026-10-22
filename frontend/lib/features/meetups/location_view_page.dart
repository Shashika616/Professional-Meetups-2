import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:url_launcher/url_launcher.dart';

import 'package:professional_connections_platform/core/maps/map_canvas.dart';
import 'package:professional_connections_platform/core/maps/map_sheet_scaffold.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/app_back_button.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

/// ADR-029 (round-8 hardening) — a read-only "View Location" preview plus
/// a "Get Directions" deep link. Gated by exactly the same
/// [Meetup.lockedForViewer] check ADR-028 already applies everywhere else
/// (no new gating concept, no participation check). No in-app routing —
/// Get Directions only ever opens the user's own installed maps app via
/// [launchUrl].
class LocationViewPage extends StatefulWidget {
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

  @override
  State<LocationViewPage> createState() => _LocationViewPageState();
}

class _LocationViewPageState extends State<LocationViewPage> {
  /// Held so the recentre control can drive the camera. Null until the
  /// platform view reports ready.
  MapCanvasController? _map;

  Meetup get meetup => widget.meetup;

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
          appBar: AppBar(title: const Text('Location')),
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
        // Pan, zoom and rotate are on. ADR-029 chose "a picture over a
        // map you can wander away from", and the picture was the right
        // call for a thumbnail — but this is the full-bleed page whose
        // whole job is answering "where is this, and what is around it",
        // and a map you cannot move cannot answer the second half. You
        // cannot see which end of the street it is, or what the nearest
        // junction is called, without moving.
        //
        // Wandering away is no longer a way to get lost, because the pin
        // is anchored to the meetup rather than to the middle of the
        // screen, and the control below recentres.
        map: MapCanvas(
          initialCentre: MapPoint(lat, lng),
          initialZoom: 16,
          marker: MapPoint(lat, lng),
          onReady: (c) => _map = c,
        ),
        topOverlay: const _FloatingBackButton(),
        // Now that the map moves, there has to be a way back. Without
        // this, panning away from the meetup is a one-way trip that only
        // leaving and reopening the page undoes.
        mapActions: MapActionButton(
          icon: AppIcons.locate,
          semanticLabel: 'Recentre on the meetup',
          onPressed: () => _map?.moveTo(MapPoint(lat, lng), zoom: 16),
        ),
        sheet: MapSheet(
          children: [
            Text(
              'Meetup location',
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppIcon(AppIcons.pin, size: 18, color: AppPalette.candyBlue),
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
              label: 'Get directions',
              icon: AppIcons.directions,
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
          // The circular chrome stays — it has to read against a map — but
          // the glyph inside it is now the platform's, so it matches every
          // other back control in the app instead of showing the Android
          // arrow to iOS users.
          icon: backButtonIconPath(context),
          semanticLabel: MaterialLocalizations.of(context).backButtonTooltip,
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
