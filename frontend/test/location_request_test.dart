import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';
import 'package:professional_connections_platform/core/utils/location.dart';

import 'support/fake_geolocator_platform.dart';

/// `requestCurrentLocation` and its one-time escalation to GPS.
///
/// The browse read asks for medium accuracy so a phone can answer from
/// network positioning in a second or two. An emulator has no network
/// positioning at all, only the injected GPS fix, and on Android a medium
/// request never turns the GPS on, so the emulator went blind the day the
/// browse read switched to medium (Sep 2026) while every phone kept
/// working. These pin the escalation that brings the emulator back without
/// changing what a phone does on the fast path.
void main() {
  late FakeGeolocatorPlatform fake;

  setUp(() {
    fake = FakeGeolocatorPlatform(position: testPosition());
    GeolocatorPlatform.instance = fake;
  });

  test('a medium read that answers never touches the GPS', () async {
    final position = await requestCurrentLocation(
      accuracy: LocationAccuracy.medium,
    );

    expect(position.latitude, 6.9271);
    expect(fake.requestedAccuracies, [LocationAccuracy.medium]);
  });

  test('a medium read that times out with nothing cached escalates once to '
      'GPS, and that answers', () async {
    fake.onlyGpsAnswers = true;

    final position = await requestCurrentLocation(
      accuracy: LocationAccuracy.medium,
    );

    expect(position.longitude, 79.8612);
    expect(fake.requestedAccuracies, [
      LocationAccuracy.medium,
      LocationAccuracy.high,
    ]);
  });

  test('a cached fix wins over escalating: no GPS read when the last known '
      'position will do', () async {
    fake.onlyGpsAnswers = true;
    fake.lastKnownPosition = testPosition(lat: 7.0, lng: 80.0);

    final position = await requestCurrentLocation(
      accuracy: LocationAccuracy.medium,
    );

    expect(position.latitude, 7.0);
    expect(fake.requestedAccuracies, [LocationAccuracy.medium]);
  });

  test('a high read that times out does not retry itself', () async {
    fake.getCurrentPositionError = TimeoutException('no fix');

    await expectLater(
      requestCurrentLocation(accuracy: LocationAccuracy.high),
      throwsA(
        isA<LocationUnavailableException>().having(
          (e) => e.reason,
          'reason',
          LocationUnavailableReason.timedOut,
        ),
      ),
    );
    expect(fake.getCurrentPositionCalls, 1);
  });

  test('when even the GPS read fails the caller still gets the timeout '
      'reason, not the escalation\'s own error', () async {
    fake.getCurrentPositionError = TimeoutException('no fix');

    await expectLater(
      requestCurrentLocation(accuracy: LocationAccuracy.medium),
      throwsA(
        isA<LocationUnavailableException>().having(
          (e) => e.reason,
          'reason',
          LocationUnavailableReason.timedOut,
        ),
      ),
    );
    expect(fake.requestedAccuracies, [
      LocationAccuracy.medium,
      LocationAccuracy.high,
    ]);
  });
}
