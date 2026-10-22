import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:apple_maps_flutter/apple_maps_flutter.dart' as apple;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as libre;

import 'package:professional_connections_platform/core/maps/map_provider.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';

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
/// my-location button, which is what a thumbnail wants. Everything the
/// user can actually look at passes true.
///
/// # A PIN AT THE CENTRE OF THE SCREEN VERSUS A PIN ON A PLACE
///
/// There are two different pins here and they are not interchangeable.
///
/// [MapCentrePin] is drawn over the middle of the viewport and never
/// moves; on a PICKER that is exactly right, because the thing being
/// picked IS the camera centre. On a VIEWER it is only right while the
/// map cannot move — the moment you let someone drag, a fixed centre pin
/// stops pointing at the meetup and starts pointing at wherever they
/// dragged to, while still looking authoritative.
///
/// [marker] is the other one: a real annotation the platform anchors to
/// a coordinate, so it stays on the place through any pan, zoom or
/// rotate. A viewer that is draggable needs this, not the overlay.
class MapCanvas extends StatefulWidget {
  const MapCanvas({
    super.key,
    required this.initialCentre,
    this.initialZoom = 13,
    this.interactive = true,
    this.marker,
    this.onReady,
    this.onCameraMove,
    this.onCameraIdle,
  });

  final MapPoint initialCentre;
  final double initialZoom;
  final bool interactive;

  /// A point the platform pins to the map itself. See the class doc for
  /// why this is not the same thing as [MapCentrePin].
  final MapPoint? marker;

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
            marker: widget.marker,
            onReady: widget.onReady,
            onCameraMove: widget.onCameraMove,
            onCameraIdle: widget.onCameraIdle,
          )
        : _LibreCanvas(
            centre: widget.initialCentre,
            zoom: widget.initialZoom,
            interactive: widget.interactive,
            marker: widget.marker,
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
    required this.marker,
    this.onReady,
    this.onCameraMove,
    this.onCameraIdle,
  });

  final MapPoint centre;
  final double zoom;
  final bool interactive;
  final MapPoint? marker;
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
      annotations: {
        if (widget.marker != null)
          apple.Annotation(
            annotationId: apple.AnnotationId('marker'),
            position: apple.LatLng(widget.marker!.lat, widget.marker!.lng),
          ),
      },
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
    required this.marker,
    this.onReady,
    this.onCameraMove,
    this.onCameraIdle,
  });

  final MapPoint centre;
  final double zoom;
  final bool interactive;
  final MapPoint? marker;
  final ValueChanged<MapCanvasController>? onReady;
  final ValueChanged<MapPoint>? onCameraMove;
  final ValueChanged<MapPoint>? onCameraIdle;

  @override
  State<_LibreCanvas> createState() => _LibreCanvasState();
}

/// MapLibre takes colours as CSS hex strings, not Dart [Color]s.
String _hex(Color c) {
  int ch(double v) => (v * 255).round().clamp(0, 255);
  return '#'
      '${ch(c.r).toRadixString(16).padLeft(2, '0')}'
      '${ch(c.g).toRadixString(16).padLeft(2, '0')}'
      '${ch(c.b).toRadixString(16).padLeft(2, '0')}';
}

/// The style-local name the pin sprite is registered under.
const String _pinImage = 'tiehere-pin';

class _LibreCanvasState extends State<_LibreCanvas> {
  libre.MapLibreMapController? _controller;

  /// The pin as PNG bytes, for [libre.MapLibreMapController.addImage].
  ///
  /// MapLibre takes a raster sprite, not an SVG, so the same markup
  /// [AppIcon] draws is rendered once into a bitmap at 3x and handed over.
  /// Rendered here rather than shipped as an asset so the marker cannot
  /// drift from the icon set: there is one definition of the pin.
  /// # WHY THE MARKER IS NOT [AppIcons.pin]
  ///
  /// The first version rasterised the UI pin straight from the icon set,
  /// on the reasoning that one definition of a pin beats two. On the map
  /// it disappeared. The icon set is drawn for UI chrome: a 1.6px stroke,
  /// no fill, 13-20px, on a surface whose colour this app picks. A map
  /// marker is none of those — it sits on tiles dense with roads, labels
  /// and parks that the app does not control, and it has to be the most
  /// findable thing on the screen.
  ///
  /// So this is drawn for the job rather than scaled up from the icon
  /// set: a solid teardrop in the brand green, a 3px white keyline so it
  /// separates from whatever tile is under it, the white centre hole that
  /// reads as "map pin" in every map anyone has used, and a contact
  /// shadow at the tip so it stands ON the map instead of being printed
  /// into it. Generated rather than shipped as an asset so it follows the
  /// palette, and rasterised at the device pixel ratio so it stays crisp.
  Future<Uint8List?> _pinSprite(double dpr) async {
    const double w = 48, h = 60;
    final fill = _hex(AppPalette.brandGreen);

    final svg =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 60">'
        '<ellipse cx="24" cy="55.5" rx="7.5" ry="2.6" '
        'fill="#000000" fill-opacity="0.22"/>'
        '<path d="M24 3a17.5 17.5 0 0 0-17.5 17.5C6.5 33.6 24 52 24 52'
        's17.5-18.4 17.5-31.5A17.5 17.5 0 0 0 24 3z" '
        'fill="$fill" stroke="#FFFFFF" stroke-width="3" '
        'stroke-linejoin="round"/>'
        '<circle cx="24" cy="20.5" r="6.4" fill="#FFFFFF"/>'
        '</svg>';

    final info = await vg.loadPicture(SvgStringLoader(svg), null);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(w * dpr / info.size.width, h * dpr / info.size.height);
    canvas.drawPicture(info.picture);
    final image = await recorder.endRecording().toImage(
      (w * dpr).round(),
      (h * dpr).round(),
    );
    info.picture.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data?.buffer.asUint8List();
  }

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
      // The marker is the app's own pin, rasterised once and registered
      // with the style, then placed as a symbol anchored to the point.
      //
      // A circle was the first attempt, because addCircle needs no image.
      // It was wrong: the pin is the mark this app uses for a place
      // everywhere else, and a blue dot on the map while a pin sits
      // beside the address underneath is two names for one thing.
      onStyleLoadedCallback: () async {
        final marker = widget.marker;
        final controller = _controller;
        if (marker == null || controller == null) return;
        // Read before the first await: MediaQuery is not safe to touch
        // across an async gap, and this is used twice below.
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final sprite = await _pinSprite(dpr);
        if (sprite == null || !mounted) return;
        await controller.addImage(_pinImage, sprite);
        await controller.addSymbol(
          libre.SymbolOptions(
            geometry: libre.LatLng(marker.lat, marker.lng),
            iconImage: _pinImage,
            // The pin's POINT is at its bottom, so that is what has to
            // sit on the coordinate; anchoring by centre would put the
            // place half a pin north of where it is.
            iconAnchor: 'bottom',
            // 1, not 1/dpr. MapLibre maps the registered bitmap's
            // pixels to SCREEN pixels, so rasterising at the device
            // pixel ratio already lands the sprite at its intended
            // logical size; dividing again shrank it to a speck.
            iconSize: 1,
          ),
        );
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
            // Just the pin. The Material glyph this replaced carried a
            // `shadows:` list, and porting it to a BoxShadow on a wrapper
            // was wrong twice over: a BoxShadow follows the BOX, not the
            // glyph, so it painted a soft rectangular smudge behind the
            // marker rather than a shadow under it. The stroke pin is
            // legible on the map on its own.
            child: AppIcon(AppIcons.pin, color: colour, size: 40),
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
