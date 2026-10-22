import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:professional_connections_platform/features/meetups/widgets/ios_map_location_step.dart';

/// The one thing no unit test can cover: that the iOS step, running on a
/// real device, actually gets completions back from MapKit through the
/// `MethodChannel` and draws them.
///
/// `LocalSearchChannelTests.swift` pins the channel's bookkeeping (every
/// pending result is answered; a repeated fragment does not wait for a
/// callback that will never come) and `test/ios_map_location_step_test.dart`
/// pins the Dart state machine against a fake channel. Between them they
/// describe the bug that was fixed — a Dart future that could never
/// complete — but neither proves the whole path works. This does, against
/// the live `MKLocalSearchCompleter`.
///
/// Run it with a booted simulator or a device:
///
///     flutter test integration_test/place_search_live_test.dart -d <id>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS: typing a venue name brings back real MapKit completions', (
    tester,
  ) async {
    if (!Platform.isIOS) {
      // The Android half of this path is HTTP, covered by
      // test/place_search_test.dart against the real response shape and
      // verified on a device.
      return;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(
            child: IosMapLocationStep(onSubmit: (_, _, _) {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(
        TextField,
        'Search for a cafe, restaurant, or venue',
      ),
      'coffee',
    );
    await tester.pump();

    // The panel is up immediately, before anything has been asked.
    expect(find.text('Looking for places…'), findsOneWidget);

    // MapKit answers over the network; poll rather than guess a duration.
    var answered = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.text('Looking for places…').evaluate().isEmpty) {
        answered = true;
        break;
      }
    }

    expect(
      answered,
      isTrue,
      reason:
          'the completer never answered — the exact hang this channel was '
          'fixed for',
    );
    expect(
      find.text('No places found'),
      findsNothing,
      reason: 'MapKit should know of somewhere called coffee',
    );
    expect(find.byType(ListTile), findsWidgets);
  });
}
