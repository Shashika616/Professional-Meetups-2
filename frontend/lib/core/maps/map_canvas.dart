import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:apple_maps_flutter/apple_maps_flutter.dart' as apple;
import 'package:maplibre_gl/maplibre_gl.dart' as libre;

import 'package:professional_connections_platform/core/maps/map_provider.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// A coordinate, without belonging to either map SDK.
///
/// Both providers have their own `LatLng` and they are not interchangeable,
/// so everything above this file speaks in [MapPoint] and only the two
/// private implementations below ever convert.
@immutable
class MapPoint {
  const MapPoint(this.lat, this.lng);

  final double lat;
  final double lng;

  @override
  bool operator ==(Object other) =>
      other is MapPoint && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);

  @override
  String toString() => 'MapPoint($lat, $lng)';
}

/// Drives a [MapCanvas] without knowing which provider drew it.
///
/// Deliberately tiny. The screens here only ever need "put the camera
/// there", and a wrapper that exposed each SDK's full controller would
/// leak the provider straight back into the callers this exists to keep
/// provider-neutral.
abstract interface class MapCanvasController {
  /// Animates the camera to [target]. Zoom is left alone when omitted.
  Future<void> moveTo(MapPoint target, {double? zoom});
}

/// The app's one map surface.
///
/// # WHY THIS EXISTS
///
/// Three screens draw a map — the two location pickers and the read-only
/// location view — and until now each carried its own copy of the
/// platform switch, the camera wiring and the gesture flags. Three copies
/// of "which SDK am I on" is three places to fix a provider bug, and the
/// copies had already drifted: the pickers tracked the camera two
/// different ways, and the pin colour rule was written out twice.
///
/// The split itself is settled and not re-litigated here: iOS renders
/// Apple Maps (no key, no billing) and Android renders MapLibre against
/// the configured tile provider (see [MapConfig]). This widget is only
/// about having one place that knows it.
///
/// # STATIC VERSUS INTERACTIVE
///
/// [interactive] false turns off every gesture, the compass and the
/// my-location button, which is what a preview wants: a picture of one
/// place that cannot be dragged away from it. The read-only location view
/// passes false; the pickers pass true.
class MapCanvas extends StatefulWidget {
  const MapCanvas({
    super.key,
    required this.initialCentre,
    this.initialZoom = 13,
    this.interactive = true,
    this.onReady,
    this.onCameraMove,
    this.onCameraIdle,
  });

  final MapPoint initialCentre;
  final double initialZoom;
  final bool interactive;

  /// Handed the controller once the platform view is up. Null for a
  /// preview that never moves the camera itself.
  final ValueChanged<MapCanvasController>? onReady;

  /// Every camera frame. Cheap to receive and called often, so callers
  /// should not setState from it — the pickers keep the value in a plain
  /// field and read it on submit.
  final ValueChanged<MapPoint>? onCameraMove;

  /// Once the camera settles. The honest "the user has chosen this point"
  /// signal for a drag-the-map picker.
  final ValueChanged<MapPoint>? onCameraIdle;

  @override
  State<MapCanvas> createState() => _MapCanvasState();
}

class _MapCanvasState extends State<MapCanvas> {
  @override
  Widget build(BuildContext context) {
    // defaultTargetPlatform, not Platform.isIOS: the former is what a
    // widget test can override, and every existing map test does.
    return defaultTargetPlatform == TargetPlatform.iOS
        ? _AppleCanvas(
            centre: widget.initialCentre,
            zoom: widget.initialZoom,
            interactive: widget.interactive,
            onReady: widget.onReady,
            onCameraMove: widget.onCameraMove,
            onCameraIdle: widget.onCameraIdle,
          )
        : _LibreCanvas(
            centre: widget.initialCentre,
            zoom: widget.initialZoom,
            interactive: widget.interactive,
            onReady: widget.onReady,
            onCameraMove: widget.onCameraMove,
            onCameraIdle: widget.onCameraIdle,
          );
  }
}

// --- Apple Maps (iOS) -------------------------------------------------

class _AppleCanvas extends StatefulWidget {
  const _AppleCanvas({
    required this.centre,
    required this.zoom,
    required this.interactive,
    this.onReady,
    this.onCameraMove,
    this.onCameraIdle,
  });

  final MapPoint centre;
  final double zoom;
  final bool interactive;
  final ValueChanged<MapCanvasController>? onReady;
  final ValueChanged<MapPoint>? onCameraMove;
  final ValueChanged<MapPoint>? onCameraIdle;

  @override
  State<_AppleCanvas> createState() => _AppleCanvasState();
}

class _AppleCanvasState extends State<_AppleCanvas> {
  /// Where the camera was last seen. apple_maps_flutter's onCameraIdle is
  /// a bare VoidCallback — it does not say where the map stopped — so the
  /// last position from onCameraMove is what settled, and this is the only
  /// way to report idle with a point the way MapLibre does.
  late MapPoint _last = widget.centre;

  @override
  Widget build(BuildContext context) {
    return apple.AppleMap(
      initialCameraPosition: apple.CameraPosition(
        target: apple.LatLng(widget.centre.lat, widget.centre.lng),
        zoom: widget.zoom,
      ),
      compassEnabled: widget.interactive,
      rotateGesturesEnabled: widget.interactive,
      scrollGesturesEnabled: widget.interactive,
      zoomGesturesEnabled: widget.interactive,
      pitchGesturesEnabled: widget.interactive,
      myLocationButtonEnabled: false,
      onMapCreated: (controller) =>
          widget.onReady?.call(_AppleController(controller, widget.zoom)),
      onCameraMove: (position) {
        _last = MapPoint(position.target.latitude, position.target.longitude);
        widget.onCameraMove?.call(_last);
      },
      onCameraIdle: widget.onCameraIdle == null
          ? null
          : () => widget.onCameraIdle!(_last),
    );
  }
}

class _AppleController implements MapCanvasController {
  _AppleController(this._controller, this._zoom);

  final apple.AppleMapController _controller;
  final double _zoom;

  @override
  Future<void> moveTo(MapPoint target, {double? zoom}) =>
      _controller.animateCamera(
        apple.CameraUpdate.newLatLngZoom(
          apple.LatLng(target.lat, target.lng),
          zoom ?? _zoom,
        ),
      );
}

// --- MapLibre (Android and everything else) ---------------------------

class _LibreCanvas extends StatefulWidget {
  const _LibreCanvas({
    required this.centre,
    required this.zoom,
    required this.interactive,
    this.onReady,
    this.onCameraMove,
    this.onCameraIdle,
  });

  final MapPoint centre;
  final double zoom;
  final bool interactive;
  final ValueChanged<MapCanvasController>? onReady;
  final ValueChanged<MapPoint>? onCameraMove;
  final ValueChanged<MapPoint>? onCameraIdle;

  @override
  State<_LibreCanvas> createState() => _LibreCanvasState();
}

class _LibreCanvasState extends State<_LibreCanvas> {
  libre.MapLibreMapController? _controller;

  @override
  Widget build(BuildContext context) {
    return libre.MapLibreMap(
      styleString: MapConfig.styleUrl(),
      initialCameraPosition: libre.CameraPosition(
        target: libre.LatLng(widget.centre.lat, widget.centre.lng),
        zoom: widget.zoom,
      ),
      compassEnabled: widget.interactive,
      rotateGesturesEnabled: widget.interactive,
      scrollGesturesEnabled: widget.interactive,
      zoomGesturesEnabled: widget.interactive,
      tiltGesturesEnabled: widget.interactive,
      myLocationEnabled: false,
      // Required for cameraPosition to be populated at all, which is how
      // the idle position is read below.
      trackCameraPosition: true,
      onMapCreated: (controller) {
        _controller = controller;
        widget.onReady?.call(_LibreController(controller, widget.zoom));
      },
      onCameraIdle: () {
        final target = _controller?.cameraPosition?.target;
        if (target == null) return;
        final point = MapPoint(target.latitude, target.longitude);
        // MapLibre has no per-frame camera callback in this package, so
        // idle feeds both: a caller listening only to onCameraMove still
        // learns where the map ended up.
        widget.onCameraMove?.call(point);
        widget.onCameraIdle?.call(point);
      },
    );
  }
}

class _LibreController implements MapCanvasController {
  _LibreController(this._controller, this._zoom);

  final libre.MapLibreMapController _controller;
  final double _zoom;

  @override
  Future<void> moveTo(MapPoint target, {double? zoom}) =>
      _controller.animateCamera(
        libre.CameraUpdate.newLatLngZoom(
          libre.LatLng(target.lat, target.lng),
          zoom ?? _zoom,
        ),
      );
}

/// The pin that marks whatever the map is centred on.
///
/// The picked point is always the centre of the camera — the pin does not
/// move, the map does, which is the pattern both pickers already used and
/// the one Uber, PickMe and Google Maps all settled on. It is a separate
/// widget from [MapCanvas] because the read-only view wants the same mark
/// over a map that cannot be dragged, and because a pin drawn in Flutter
/// needs no annotation or symbol API from either SDK.
class MapCentrePin extends StatelessWidget {
  const MapCentrePin({super.key, this.lifted = false});

  /// Raises the pin and drops a shadow under it, so a drag reads as the
  /// map sliding beneath a pin held above it.
  final bool lifted;

  @override
  Widget build(BuildContext context) {
    // iOS keeps the app accent over Apple's tiles; Android takes the
    // colour that reads on the configured tile provider. This was written
    // out separately in all three map screens before.
    final colour = defaultTargetPlatform == TargetPlatform.iOS
        ? AppPalette.candyBlue
        : MapConfig.pinColor;
    return IgnorePointer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSlide(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            offset: Offset(0, lifted ? -0.18 : 0),
            child: Icon(
              Icons.location_on,
              color: colour,
              size: 40,
              shadows: [
                Shadow(
                  color: AppPalette.onyx.withValues(alpha: 0.55),
                  blurRadius: 8,
                ),
              ],
            ),
          ),
          // The point actually being picked, so a lifted pin still shows
          // exactly which spot it refers to.
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: lifted ? 8 : 0,
            height: lifted ? 8 : 0,
            decoration: BoxDecoration(
              color: colour,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
            ),
          ),
          // Keeps the pin's tip on the centre: the icon is drawn from its
          // box centre, so without this the tip sits below the target.
          SizedBox(height: lifted ? 12 : 20),
        ],
      ),
    );
  }
}
