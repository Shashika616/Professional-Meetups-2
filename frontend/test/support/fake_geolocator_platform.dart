import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';

/// A settable `GeolocatorPlatform.instance` for widget tests
/// (`core/utils/location.dart`'s `requestCurrentLocation` — no existing
/// test in this codebase mocks Geolocator at all, this is the first).
/// Only the four methods `requestCurrentLocation` actually calls are
/// overridden; everything else falls through to the base class's default
/// `UnimplementedError`, same pattern real platform implementations use.
class FakeGeolocatorPlatform extends GeolocatorPlatform {
  FakeGeolocatorPlatform({
    this.serviceEnabled = true,
    this.permission = LocationPermission.whileInUse,
    this.position,
    this.getCurrentPositionError,
  });

  bool serviceEnabled;
  LocationPermission permission;
  Position? position;
  Object? getCurrentPositionError;

  @override
  Future<bool> isLocationServiceEnabled() async => serviceEnabled;

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async => permission;

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    if (getCurrentPositionError != null) throw getCurrentPositionError!;
    return position!;
  }
}

Position testPosition({double lat = 6.9271, double lng = 79.8612}) {
  return Position(
    latitude: lat,
    longitude: lng,
    timestamp: DateTime.now(),
    accuracy: 5,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );
}
