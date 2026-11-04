import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/features/home/location_explanation_page.dart';
import 'package:professional_connections_platform/features/home/viewer_location_provider.dart';
import 'package:professional_connections_platform/features/meetups/widgets/other_meetups_nearby.dart';

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

class _Explanation implements LocationExplanation {
  _Explanation({required this.owed});

  bool owed;
  int marks = 0;

  @override
  Future<bool> needed() async => owed;

  @override
  Future<void> markShown() async {
    marks++;
    owed = false;
  }
}

void main() {
  group('the explanation comes before the first prompt', () {
    late _Explanation explanation;
    late int reads;
    late ProviderContainer container;

    setUp(() {
      explanation = _Explanation(owed: true);
      reads = 0;
      container = ProviderContainer(
        overrides: [
          authServiceProvider.overrideWithValue(ImmediateAuthService()),
          locationExplanationProvider.overrideWithValue(explanation),
          viewerLocationSourceProvider.overrideWithValue(() async {
            reads++;
            return _at(6.92714, 79.86124);
          }),
        ],
      );
      addTearDown(container.dispose);
    });

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('nothing is read until the person continues', () async {
      final sub = container.listen(viewerLocationProvider, (_, _) {});
      addTearDown(sub.close);
      await settle();
      expect(
        container.read(viewerLocationProvider).status,
        ViewerLocationStatus.needsExplanation,
      );
      expect(reads, 0);

      await container
          .read(viewerLocationProvider.notifier)
          .explanationAccepted();
      expect(explanation.marks, 1);
      expect(reads, 1);
      expect(
        container.read(viewerLocationProvider).status,
        ViewerLocationStatus.ready,
      );
    });

    test('not now reads nothing, and try again explains again', () async {
      final sub = container.listen(viewerLocationProvider, (_, _) {});
      addTearDown(sub.close);
      await settle();
      final notifier = container.read(viewerLocationProvider.notifier);
      notifier.explanationDeclined();
      expect(reads, 0);
      expect(explanation.marks, 0);
      expect(
        container.read(viewerLocationProvider).status,
        ViewerLocationStatus.blocked,
      );

      await notifier.refresh();
      expect(
        container.read(viewerLocationProvider).status,
        ViewerLocationStatus.needsExplanation,
      );
    });
  });

  testWidgets('the explanation page answers for both buttons', (tester) async {
    final answers = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                answers.add(await LocationExplanationPage.show(context)),
            child: const Text('open'),
          ),
        ),
      ),
    );
    for (final label in ['Continue', 'Not now']) {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    expect(answers, [true, false]);
  });

  test('only the rounded position is reported to the server', () async {
    final auth = ImmediateAuthService();
    final container = ProviderContainer(
      overrides: [
        authServiceProvider.overrideWithValue(auth),
        viewerLocationSourceProvider.overrideWithValue(
          () async => _at(6.927149, 79.861249),
        ),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(viewerLocationProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(viewerLocationProvider.notifier).refresh();
    await Future<void>.delayed(Duration.zero);
    expect(auth.lastUpdateLastKnownLocationLat, 6.927);
    expect(auth.lastUpdateLastKnownLocationLng, 79.861);
    expect(container.read(knownViewerLocationProvider), (
      lat: 6.927,
      lng: 79.861,
    ));
  });

  testWidgets('the meetup page never starts a location read', (tester) async {
    var reads = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(ImmediateAuthService()),
          viewerLocationSourceProvider.overrideWithValue(() async {
            reads++;
            return _at(6.9, 79.8);
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: OtherMeetupsNearby(excludeMeetupId: 'm', onOpen: (_) {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(reads, 0);
    expect(find.text('Browse meetups'), findsOneWidget);
  });

  test('iOS asks for while-in-use only, and says what it is for', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(plist, isNot(contains('NSLocationAlways')));
    expect(plist, contains('NSLocationWhenInUseUsageDescription'));
    expect(plist, contains('an SOS you send'));
    expect(plist, isNot(contains('one-time lookup')));
  });
}
