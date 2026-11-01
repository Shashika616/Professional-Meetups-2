import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/analytics/event_names.g.dart';
import 'package:professional_connections_platform/core/analytics/friction.dart';

import '../support/analytics_harness.dart';

void main() {
  group('rage taps', () {
    late List<int> reported;
    late int generation;
    late RageTapDetector detector;

    setUp(() {
      reported = [];
      generation = 0;
      detector = RageTapDetector(
        generation: () => generation,
        onRageTap: reported.add,
      );
    });

    test('three taps within a second on one spot: reported once', () {
      fakeAsync((async) {
        detector.tap(const Offset(100, 100));
        async.elapse(const Duration(milliseconds: 300));
        detector.tap(const Offset(110, 105));
        async.elapse(const Duration(milliseconds: 300));
        detector.tap(const Offset(95, 98));
        expect(reported, [3]);
        // A fourth in the same burst is the same rage, not a new one.
        async.elapse(const Duration(milliseconds: 100));
        detector.tap(const Offset(100, 100));
        expect(reported, [3]);
      });
    });

    test(
      'too slow, too far apart, or a screen change in between: not rage',
      () {
        fakeAsync((async) {
          // Slow: the third tap lands 1.2 s after the first.
          detector.tap(const Offset(100, 100));
          async.elapse(const Duration(milliseconds: 600));
          detector.tap(const Offset(100, 100));
          async.elapse(const Duration(milliseconds: 600));
          detector.tap(const Offset(100, 100));
          expect(reported, isEmpty);

          // Spread out: more than 24 px from the first.
          async.elapse(const Duration(seconds: 2));
          detector.tap(const Offset(100, 100));
          detector.tap(const Offset(130, 100));
          detector.tap(const Offset(100, 130));
          expect(reported, isEmpty);

          // Navigation between taps: a user moving through screens fast.
          async.elapse(const Duration(seconds: 2));
          detector.tap(const Offset(100, 100));
          generation++;
          detector.tap(const Offset(100, 100));
          generation++;
          detector.tap(const Offset(100, 100));
          expect(reported, isEmpty);
        });
      },
    );

    testWidgets('the app-wide listener reports through analytics, without '
        'stopping the tap', (tester) async {
      final analytics = await installTestAnalytics();
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: RageTapListener(
            child: Center(
              child: TextButton(
                onPressed: () => taps++,
                child: const Text('Pay'),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Pay'));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(taps, 3);
      expect(names(analytics), contains(AnalyticsEvent.rageTap));
    });
  });

  group('long dwell', () {
    test('a minute without input on a form step: reported once', () {
      fakeAsync((async) {
        final reported = <int>[];
        final watcher = DwellWatcher(onDwell: reported.add)..start();
        async.elapse(const Duration(seconds: 59));
        expect(reported, isEmpty);
        async.elapse(const Duration(seconds: 1));
        expect(reported, [60000]);
        async.elapse(const Duration(minutes: 5));
        expect(reported, [60000], reason: 'once per step');
        watcher.stop();
      });
    });

    test('input restarts the minute; a new step restarts the watch', () {
      fakeAsync((async) {
        final reported = <int>[];
        final watcher = DwellWatcher(onDwell: reported.add)..start();
        async.elapse(const Duration(seconds: 50));
        watcher.activity();
        async.elapse(const Duration(seconds: 50));
        expect(reported, isEmpty);
        async.elapse(const Duration(seconds: 10));
        expect(reported, hasLength(1));
        watcher.start(); // the next step
        async.elapse(const Duration(seconds: 60));
        expect(reported, hasLength(2));
        watcher.stop();
        async.elapse(const Duration(minutes: 5));
        expect(reported, hasLength(2));
      });
    });

    testWidgets('DwellTracker: a tap inside counts as input', (tester) async {
      final analytics = await installTestAnalytics();
      await tester.pumpWidget(
        const MaterialApp(
          home: DwellTracker(child: Center(child: Text('form'))),
        ),
      );
      await tester.pump(const Duration(seconds: 40));
      await tester.tap(find.text('form'));
      await tester.pump(const Duration(seconds: 40));
      expect(names(analytics), isNot(contains(AnalyticsEvent.longDwell)));
      await tester.pump(const Duration(seconds: 21));
      expect(names(analytics), contains(AnalyticsEvent.longDwell));
      // Leaving the step cancels the watch (no timer left behind).
      await tester.pumpWidget(const SizedBox());
    });
  });
}
