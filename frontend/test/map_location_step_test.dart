import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/features/meetups/widgets/ios_map_location_step.dart';
import 'package:professional_connections_platform/features/meetups/widgets/map_location_step.dart';
import 'package:professional_connections_platform/features/meetups/widgets/android_map_location_step.dart';

void main() {
  testWidgets('picks IosMapLocationStep on iOS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            // Given bounded height, as ScheduleFlowPage does: the step is
            // a full-bleed map now, not a scrolled column.
            body: SizedBox.expand(
              child: MapLocationStep(onSubmit: (_, _, _) {}),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(IosMapLocationStep), findsOneWidget);
      expect(find.byType(AndroidMapLocationStep), findsNothing);
    } finally {
      // Reset synchronously before the test body returns — Flutter's own
      // end-of-test invariant check runs before a plain top-level
      // addTearDown callback gets a chance to.
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('picks AndroidMapLocationStep on Android', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            // Given bounded height, as ScheduleFlowPage does: the step is
            // a full-bleed map now, not a scrolled column.
            body: SizedBox.expand(
              child: MapLocationStep(onSubmit: (_, _, _) {}),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(AndroidMapLocationStep), findsOneWidget);
      expect(find.byType(IosMapLocationStep), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
