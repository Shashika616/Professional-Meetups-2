import 'dart:async' show Completer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';

import 'package:professional_connections_platform/features/meetups/widgets/ios_map_location_step.dart';

import 'support/fake_geolocator_platform.dart';

const _channel = MethodChannel('professionalconnections/ios_local_search');

// Every step is mounted inside a SingleChildScrollView here because that is
// exactly how ScheduleFlowPage hosts it (schedule_flow.dart) — the step's
// content is taller than a bare test viewport and is designed to scroll.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  testWidgets('debounces: several rapid keystrokes collapse into exactly one '
      'autocomplete call', (tester) async {
    var autocompleteCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'autocomplete') {
            autocompleteCalls++;
            return [
              {'title': 'The Coffee Shop', 'subtitle': 'Colombo'},
            ];
          }
          return null;
        });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: IosMapLocationStep(onSubmit: (_, _, _) {}),
          ),
        ),
      ),
    );
    await tester.pump();

    final field = find.widgetWithText(
      TextField,
      'Search for a cafe, restaurant, or venue',
    );
    for (final partial in ['c', 'co', 'cof', 'coff', 'coffee']) {
      await tester.enterText(field, partial);
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      autocompleteCalls,
      0,
      reason: 'no request before the debounce settles',
    );

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(
      autocompleteCalls,
      1,
      reason: 'one debounce-settled request, not one per keystroke',
    );
  });

  testWidgets(
    'selecting a completion resolves it, fills the field, recenters, and '
    'CONTINUE submits those coordinates',
    (tester) async {
      double? submittedLat;
      double? submittedLng;
      String? submittedLabel;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            switch (call.method) {
              case 'autocomplete':
                return [
                  {'title': 'The Coffee Shop', 'subtitle': 'Colombo'},
                ];
              case 'resolveCompletion':
                return {
                  'lat': 6.9213,
                  'lon': 79.8756,
                  'label': 'The Coffee Shop, Colombo',
                };
              default:
                return null;
            }
          });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: IosMapLocationStep(
                onSubmit: (lat, lng, label) {
                  submittedLat = lat;
                  submittedLng = lng;
                  submittedLabel = label;
                },
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

      expect(find.text('The Coffee Shop, Colombo'), findsOneWidget);
      await tester.tap(find.text('The Coffee Shop, Colombo'));
      await tester.pump();
      await tester.pump();

      await tester.ensureVisible(find.text('CONTINUE'));
      await tester.pump();
      await tester.tap(find.text('CONTINUE'));
      await tester.pump();

      expect(submittedLat, closeTo(6.9213, 0.0001));
      expect(submittedLng, closeTo(79.8756, 0.0001));
      expect(submittedLabel, 'The Coffee Shop, Colombo');
    },
  );

  testWidgets(
    'a stale in-flight autocomplete request landing after a completion is '
    'selected does not reopen the dropdown (regression: cancelling the '
    'debounce Timer alone does not stop a request that already fired)',
    (tester) async {
      var autocompleteCalls = 0;
      final secondCallResponse = Completer<List<Map<String, String>>>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            switch (call.method) {
              case 'autocomplete':
                autocompleteCalls++;
                if (autocompleteCalls == 1) {
                  return [
                    {'title': 'The Coffee Shop', 'subtitle': 'Colombo'},
                  ];
                }
                // Simulates a slow second request still in flight when the
                // user taps a suggestion from the first, already-resolved
                // list below.
                return secondCallResponse.future;
              case 'resolveCompletion':
                return {
                  'lat': 6.9213,
                  'lon': 79.8756,
                  'label': 'The Coffee Shop, Colombo',
                };
              default:
                return null;
            }
          });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: IosMapLocationStep(onSubmit: (_, _, _) {}),
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

      expect(find.text('The Coffee Shop, Colombo'), findsOneWidget);

      // A further keystroke starts a second, slow request — still
      // in-flight (blocked on secondCallResponse) when the tap below
      // fires.
      await tester.enterText(field, 'coffee shop near me');
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('The Coffee Shop, Colombo'));
      await tester.pump();
      await tester.pump();

      // Now let the stale second request resolve.
      secondCallResponse.complete([
        {'title': 'Stale Result', 'subtitle': 'Should not appear'},
      ]);
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
    },
  );

  testWidgets(
    'typing a full query and pressing search submits directly, without '
    'picking a completion, and CONTINUE submits those coordinates',
    (tester) async {
      double? submittedLat;
      double? submittedLng;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (call.method == 'search') {
              return {
                'lat': 6.9172,
                'lon': 79.8634,
                'label': 'Department of Coffee',
              };
            }
            return null;
          });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: IosMapLocationStep(
                onSubmit: (lat, lng, _) {
                  submittedLat = lat;
                  submittedLng = lng;
                },
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
        'Department of Coffee',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump();

      expect(find.text('Department of Coffee'), findsWidgets);

      await tester.ensureVisible(find.text('CONTINUE'));
      await tester.pump();
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
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (call.method == 'autocomplete') {
              return [
                {'title': 'The Coffee Shop', 'subtitle': 'Colombo'},
              ];
            }
            return null;
          });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: IosMapLocationStep(
                onSubmit: (_, _, _) => submitted = true,
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

      expect(find.text('The Coffee Shop, Colombo'), findsOneWidget);
      // CONTINUE is enabled (the field has text) but sits underneath the
      // scrim while the dropdown is open — before the scrim, this tap
      // reached CONTINUE directly, which is exactly the bug being fixed
      // (submitting instead of picking a completion).
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
        find.text('The Coffee Shop, Colombo'),
        findsNothing,
        reason: 'tapping the scrim dismisses the dropdown',
      );
    },
  );

  testWidgets(
    'runs with no configuration at all — no API key, no AppConfig entry '
    'needed on iOS',
    (tester) async {
      // No debugStadiaApiKeyOverride, no AppConfig.stadiaMapsApiKey set
      // anywhere in this test — this file never even imports AppConfig,
      // confirming the iOS path has no such dependency (frontend/meetup-
      // scheduling-PLAN.md's 2026-08-18 platform-split addendum's own
      // self-review requirement).
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async => null);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: IosMapLocationStep(onSubmit: (_, _, _) {}),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Where?'), findsOneWidget);
      expect(find.text('CONTINUE'), findsOneWidget);
      expect(find.textContaining('not configured'), findsNothing);
    },
  );

  testWidgets(
    '"use my current location" no longer fills the field with a hardcoded '
    'placeholder — the field stays empty and CONTINUE still submits an '
    'empty label (ADR-029, round-8 hardening)',
    (tester) async {
      GeolocatorPlatform.instance = FakeGeolocatorPlatform(
        position: testPosition(lat: 6.9213, lng: 79.8756),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async => null);

      double? submittedLat;
      double? submittedLng;
      String? submittedLabel;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: IosMapLocationStep(
                onSubmit: (lat, lng, label) {
                  submittedLat = lat;
                  submittedLng = lng;
                  submittedLabel = label;
                },
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
      // The selection is read back under the map instead of a blank field.
      expect(find.text('Your current location'), findsOneWidget);

      // CONTINUE must still be enabled even with an empty field — using
      // current location is itself enough to unlock it.
      await tester.ensureVisible(find.text('CONTINUE'));
      await tester.pump();
      await tester.tap(find.text('CONTINUE'));
      await tester.pump();

      expect(submittedLat, closeTo(6.9213, 0.0001));
      expect(submittedLng, closeTo(79.8756, 0.0001));
      expect(submittedLabel, isEmpty);
    },
  );
}
