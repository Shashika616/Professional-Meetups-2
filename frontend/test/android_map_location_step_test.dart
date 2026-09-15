import 'dart:async' show Completer, TimeoutException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:professional_connections_platform/features/meetups/widgets/android_map_location_step.dart';

import 'support/fake_geolocator_platform.dart';

/// A minimal GeoJSON FeatureCollection in Photon's real response shape
/// (OSM tags under properties, no pre-built label): the default provider
/// under test. The step composes the label from `name` alone here so the
/// tests can look the place up by the same string they supplied.
String _featureCollection(List<(String label, double lat, double lon)> places) {
  final features = places
      .map(
        (p) =>
            '{"type":"Feature","geometry":{"type":"Point","coordinates":[${p.$3},${p.$2}]},'
            '"properties":{"name":"${p.$1}","osm_key":"amenity","osm_value":"cafe"}}',
      )
      .join(',');
  return '{"type":"FeatureCollection","features":[$features]}';
}

// Every step is mounted inside a SingleChildScrollView here because that is
// exactly how ScheduleFlowPage hosts it (schedule_flow.dart) — the step's
// content is taller than a bare test viewport and is designed to scroll.
void main() {
  testWidgets(
    'debounces: several rapid keystrokes collapse into exactly one request',
    (tester) async {
      var requestCount = 0;
      final client = MockClient((request) async {
        requestCount++;
        return http.Response(
          _featureCollection([('The Coffee Shop', 6.9213, 79.8756)]),
          200,
        );
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AndroidMapLocationStep(
                onSubmit: (_, _, _) {},
                httpClient: client,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final field = find.widgetWithText(
        TextField,
        'Search for a cafe, restaurant, or venue',
      );
      // Five keystrokes, each only a single frame apart — well within the
      // 300ms debounce window, so none of them should fire their own
      // request.
      for (final partial in ['c', 'co', 'cof', 'coff', 'coffee']) {
        await tester.enterText(field, partial);
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(requestCount, 0, reason: 'no request before the debounce settles');

      // Let the debounce window elapse.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(
        requestCount,
        1,
        reason: 'one debounce-settled request, not one per keystroke',
      );
    },
  );

  testWidgets('selecting a suggestion fills the field, recenters, and CONTINUE '
      'submits those coordinates', (tester) async {
    double? submittedLat;
    double? submittedLng;
    String? submittedLabel;
    final client = MockClient((request) async {
      return http.Response(
        _featureCollection([('The Coffee Shop', 6.9213, 79.8756)]),
        200,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AndroidMapLocationStep(
              onSubmit: (lat, lng, label) {
                submittedLat = lat;
                submittedLng = lng;
                submittedLabel = label;
              },
              httpClient: client,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(
      find.widgetWithText(TextField, 'Search for a cafe, restaurant, or venue'),
      'coffee',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(find.text('The Coffee Shop'), findsOneWidget);
    await tester.tap(find.text('The Coffee Shop'));
    await tester.pump();
    await tester.pump();

    await tester.ensureVisible(find.text('CONTINUE'));
    await tester.tap(find.text('CONTINUE'));
    await tester.pump();

    expect(submittedLat, closeTo(6.9213, 0.0001));
    expect(submittedLng, closeTo(79.8756, 0.0001));
    expect(submittedLabel, 'The Coffee Shop');
  });

  testWidgets(
    'the IME re-delivering the chosen label after a selection does not '
    'search again or reopen the dropdown',
    (tester) async {
      var requestCount = 0;
      final client = MockClient((request) async {
        requestCount++;
        return http.Response(
          _featureCollection([('Galle Face Green', 6.927, 79.845)]),
          200,
        );
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AndroidMapLocationStep(
                onSubmit: (_, _, _) {},
                httpClient: client,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final field = find.widgetWithText(
        TextField,
        'Search for a cafe, restaurant, or venue',
      );
      await tester.enterText(field, 'galle');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(requestCount, 1);

      await tester.tap(find.text('Galle Face Green').last);
      await tester.pump();
      // What a keyboard's autocorrect pass does: sets the same text again.
      await tester.enterText(field, 'Galle Face Green');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();

      expect(requestCount, 1, reason: 'the chosen label is not a new query');
      // The field and the SelectedPlaceBanner carry the label; a reopened
      // dropdown would add a third.
      expect(find.text('Galle Face Green'), findsNWidgets(2));
    },
  );

  testWidgets('a stale in-flight suggestions request landing after a result is '
      'selected does not reopen the dropdown (regression: cancelling the '
      'debounce Timer alone does not stop a request that already fired)', (
    tester,
  ) async {
    var requestCount = 0;
    final secondResponse = Completer<http.Response>();
    final client = MockClient((request) async {
      requestCount++;
      if (requestCount == 1) {
        return http.Response(
          _featureCollection([('The Coffee Shop', 6.9213, 79.8756)]),
          200,
        );
      }
      // Simulates a slow second request still in flight when the user
      // taps a suggestion from the first, already-resolved list below.
      return secondResponse.future;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AndroidMapLocationStep(
              onSubmit: (_, _, _) {},
              httpClient: client,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final field = find.widgetWithText(
      TextField,
      'Search for a cafe, restaurant, or venue',
    );
    await tester.enterText(field, 'coffee');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(find.text('The Coffee Shop'), findsOneWidget);

    // A further keystroke starts a second, slow request — still
    // in-flight (blocked on secondResponse) when the tap below fires.
    await tester.enterText(field, 'coffee shop near me');
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('The Coffee Shop'));
    await tester.pump();
    await tester.pump();

    // Now let the stale second request resolve.
    secondResponse.complete(
      http.Response(_featureCollection([('Stale Result', 1.0, 1.0)]), 200),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text('Stale Result'),
      findsNothing,
      reason:
          'a request in flight before the selection must be discarded, '
          'not repopulate the dropdown after the user already picked an '
          'address',
    );
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets(
    'typing a full query and pressing search submits directly, without '
    'picking a suggestion, and CONTINUE submits those coordinates',
    (tester) async {
      double? submittedLat;
      double? submittedLng;
      final client = MockClient((request) async {
        expect(request.url.host, 'photon.komoot.io');
        expect(request.url.queryParameters['limit'], '1');
        return http.Response(
          _featureCollection([('Department of Coffee', 6.9172, 79.8634)]),
          200,
        );
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AndroidMapLocationStep(
                onSubmit: (lat, lng, _) {
                  submittedLat = lat;
                  submittedLng = lng;
                },
                httpClient: client,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.enterText(
        find.widgetWithText(
          TextField,
          'Search for a cafe, restaurant, or venue',
        ),
        'Department of Coffee',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump();

      expect(find.text('Department of Coffee'), findsWidgets);

      await tester.ensureVisible(find.text('CONTINUE'));
      await tester.tap(find.text('CONTINUE'));
      await tester.pump();

      expect(submittedLat, closeTo(6.9172, 0.0001));
      expect(submittedLng, closeTo(79.8634, 0.0001));
    },
  );

  testWidgets(
    'the scrim behind an open dropdown blocks taps to CONTINUE and closes '
    'the dropdown instead of submitting',
    (tester) async {
      var submitted = false;
      final client = MockClient((request) async {
        return http.Response(
          _featureCollection([('The Coffee Shop', 6.9213, 79.8756)]),
          200,
        );
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AndroidMapLocationStep(
                onSubmit: (_, _, _) => submitted = true,
                httpClient: client,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.enterText(
        find.widgetWithText(
          TextField,
          'Search for a cafe, restaurant, or venue',
        ),
        'coffee',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(find.text('The Coffee Shop'), findsOneWidget);
      // CONTINUE is enabled (the field has text) but sits underneath the
      // scrim while the dropdown is open — before the scrim, this tap
      // reached CONTINUE directly, which is exactly the bug being fixed
      // (submitting instead of picking a suggestion).
      await tester.ensureVisible(find.text('CONTINUE'));
      await tester.pump();
      await tester.tap(find.text('CONTINUE'), warnIfMissed: false);
      await tester.pump();

      expect(
        submitted,
        false,
        reason: 'the tap should hit the scrim, not CONTINUE underneath it',
      );
      expect(
        find.text('The Coffee Shop'),
        findsNothing,
        reason: 'tapping the scrim dismisses the dropdown',
      );
    },
  );

  testWidgets('a non-200 response leaves the suggestions list empty', (
    tester,
  ) async {
    final client = MockClient((request) async => http.Response('', 401));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AndroidMapLocationStep(
              onSubmit: (_, _, _) {},
              httpClient: client,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(
      find.widgetWithText(TextField, 'Search for a cafe, restaurant, or venue'),
      'coffee',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets(
    '"use my current location" no longer fills the field with a hardcoded '
    'placeholder — the field stays empty and CONTINUE still submits an '
    'empty label (ADR-029, round-8 hardening)',
    (tester) async {
      GeolocatorPlatform.instance = FakeGeolocatorPlatform(
        position: testPosition(lat: 6.9213, lng: 79.8756),
      );

      double? submittedLat;
      double? submittedLng;
      String? submittedLabel;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AndroidMapLocationStep(
                onSubmit: (lat, lng, label) {
                  submittedLat = lat;
                  submittedLng = lng;
                  submittedLabel = label;
                },
                httpClient: MockClient(
                  (request) async => http.Response(_featureCollection([]), 200),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('USE MY CURRENT LOCATION'));
      await tester.pump();
      await tester.pump();

      // The old hardcoded placeholder is gone — never shown, never
      // submitted. The field stays empty; the server reverse-geocodes it.
      expect(find.text('Current location'), findsNothing);
      final field = find.widgetWithText(
        TextField,
        'Search for a cafe, restaurant, or venue',
      );
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);

      // The selection is read back under the map instead of a blank
      // field — the banner names the current-location case explicitly.
      expect(find.text('Your current location'), findsOneWidget);

      // CONTINUE must still be enabled even with an empty field — using
      // current location is itself enough to unlock it. The banner pushes
      // it below the test viewport, so scroll it in first.
      await tester.ensureVisible(find.text('CONTINUE'));
      await tester.tap(find.text('CONTINUE'));
      await tester.pump();

      expect(submittedLat, closeTo(6.9213, 0.0001));
      expect(submittedLng, closeTo(79.8756, 0.0001));
      expect(submittedLabel, isEmpty);
    },
  );

  Future<void> pumpStep(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AndroidMapLocationStep(
            onSubmit: (_, _, _) {},
            httpClient: MockClient(
              (request) async => http.Response(_featureCollection([]), 200),
            ),
          ),
        ),
      ),
    ),
  );

  group(
    '"use my current location" goes through the shared location helper',
    () {
      testWidgets(
        'a denied permission says so with a SETTINGS action and picks '
        'nothing',
        (tester) async {
          GeolocatorPlatform.instance = FakeGeolocatorPlatform(
            permission: LocationPermission.deniedForever,
          );
          await pumpStep(tester);
          await tester.pump();

          await tester.tap(find.text('USE MY CURRENT LOCATION'));
          await tester.pump();
          await tester.pump();

          expect(find.textContaining('permission was denied'), findsOneWidget);
          expect(find.text('SETTINGS'), findsOneWidget);
          expect(find.text('Your current location'), findsNothing);
        },
      );

      testWidgets('a fix that does not arrive falls back to the last known '
          'position instead of hanging', (tester) async {
        GeolocatorPlatform.instance = FakeGeolocatorPlatform(
          getCurrentPositionError: TimeoutException('no fix'),
          lastKnownPosition: testPosition(lat: 6.9, lng: 79.8),
        );
        await pumpStep(tester);
        await tester.pump();

        await tester.tap(find.text('USE MY CURRENT LOCATION'));
        await tester.pump();
        await tester.pump();

        expect(find.text('Your current location'), findsOneWidget);
      });

      testWidgets('the button reports that it is working while the fix is '
          'fetched, and ignores a second tap', (tester) async {
        final fake = FakeGeolocatorPlatform(
          position: testPosition(lat: 6.9, lng: 79.8),
          delay: const Duration(seconds: 2),
        );
        GeolocatorPlatform.instance = fake;
        await pumpStep(tester);
        await tester.pump();

        await tester.tap(find.text('USE MY CURRENT LOCATION'));
        await tester.pump();
        expect(find.text('FINDING YOU...'), findsOneWidget);
        await tester.tap(find.text('FINDING YOU...'), warnIfMissed: false);
        await tester.pump(const Duration(seconds: 3));

        expect(fake.getCurrentPositionCalls, 1);
        expect(find.text('USE MY CURRENT LOCATION'), findsOneWidget);
        expect(find.text('Your current location'), findsOneWidget);
      });
    },
  );
}
