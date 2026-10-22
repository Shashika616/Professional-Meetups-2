import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/features/home/viewer_location_provider.dart';

import 'support/fake_auth_service.dart';

Position _at(double lat, double lng) => Position(
  latitude: lat,
  longitude: lng,
  timestamp: DateTime.now(),
  accuracy: 10,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

void main() {
  // Every home load and pull to refresh read the location and sent it to
  // the server, changed or not: a request and a radio wake-up per refresh
  // for nothing. Now an unchanged position is sent at most once an hour.
  test('an unchanged position is reported once, a moved one again', () async {
    var position = _at(6.9271, 79.8612);
    final auth = ImmediateAuthService();
    final container = ProviderContainer(
      overrides: [
        authServiceProvider.overrideWithValue(auth),
        viewerLocationSourceProvider.overrideWithValue(() async => position),
      ],
    );
    addTearDown(container.dispose);

    final sub = container.listen(viewerLocationProvider, (_, _) {});
    addTearDown(sub.close);
    final notifier = container.read(viewerLocationProvider.notifier);

    await notifier.refresh();
    await pumpEventQueue();
    expect(auth.updateLastKnownLocationCallCount, 1);

    // Same spot, a few metres of jitter, refreshed twice.
    position = _at(6.92712, 79.86121);
    await notifier.refresh();
    await notifier.refresh();
    await pumpEventQueue();
    expect(
      auth.updateLastKnownLocationCallCount,
      1,
      reason: 'an unchanged position was re-sent',
    );

    // Moved across town.
    position = _at(6.8800, 79.9000);
    await notifier.refresh();
    await pumpEventQueue();
    expect(auth.updateLastKnownLocationCallCount, 2);
  });
}
