import 'dart:async';

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
    this.lastKnownPosition,
    this.delay = Duration.zero,
  });

  bool serviceEnabled;
  LocationPermission permission;
  Position? position;
  Object? getCurrentPositionError;

  /// What getLastKnownPosition answers; null (the default) is "nothing
  /// cached", which is the common case on a fresh device.
  Position? lastKnownPosition;
  int getCurrentPositionCalls = 0;

  /// How long getCurrentPosition takes to answer, for tests of what the
  /// UI shows while a fix is in flight.
  Duration delay;

  /// When set, any read below high accuracy times out and only a high
  /// (GPS) read answers, which is how an emulator behaves: no network
  /// positioning, only the injected GPS fix. Lets a test prove the
  /// medium-to-GPS escalation in `requestCurrentLocation`.
  bool onlyGpsAnswers = false;

  /// The accuracy of every getCurrentPosition call, in order.
  final List<LocationAccuracy?> requestedAccuracies = [];

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
    getCurrentPositionCalls++;
    requestedAccuracies.add(locationSettings?.accuracy);
    if (delay > Duration.zero) {
      // The real platform enforces LocationSettings.timeLimit natively and
      // throws TimeoutException when it passes; a read slower than its
      // limit must do the same here or budget tests measure the fake.
      final limit = locationSettings?.timeLimit;
      if (limit != null && delay > limit) {
        await Future<void>.delayed(limit);
        throw TimeoutException('no fix within $limit');
      }
      await Future<void>.delayed(delay);
    }
    if (getCurrentPositionError != null) throw getCurrentPositionError!;
    if (onlyGpsAnswers) {
      final accuracy = locationSettings?.accuracy ?? LocationAccuracy.best;
      final isGps =
          accuracy == LocationAccuracy.high ||
          accuracy == LocationAccuracy.best ||
          accuracy == LocationAccuracy.bestForNavigation;
      if (!isGps) throw TimeoutException('no network positioning');
    }
    return position!;
  }

  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async => lastKnownPosition;
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
