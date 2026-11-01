import 'package:flutter_driver/flutter_driver.dart' as driver;
import 'package:integration_test/integration_test_driver.dart';

/// Writes one timeline summary per `traceAction` the perf test reports,
/// to `build/<name>.timeline_summary.json`. Run with:
///
///   flutter drive --profile --driver=test_driver/perf_driver.dart \
///     --target=integration_test/perf_test.dart
Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    if (data == null) {
      // ignore: avoid_print
      print('perf: no timeline data reported');
      return;
    }
    for (final entry in data.entries) {
      final timeline = driver.Timeline.fromJson(
        entry.value as Map<String, dynamic>,
      );
      await driver.TimelineSummary.summarize(
        timeline,
      ).writeTimelineToFile(entry.key, pretty: true, includeSummary: true);
      // ignore: avoid_print
      print('perf: wrote ${entry.key}.timeline_summary.json');
    }
  },
);
