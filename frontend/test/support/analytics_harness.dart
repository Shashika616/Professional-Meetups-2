import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/analytics/analytics.dart';
import 'package:professional_connections_platform/core/analytics/analytics_client.dart';
import 'package:professional_connections_platform/core/analytics/analytics_queue.dart';
import 'package:professional_connections_platform/core/analytics/analytics_transport.dart';

/// Records every batch and consent call; answers with [next].
class FakeAnalyticsTransport implements AnalyticsTransport {
  int aborts = 0;

  @override
  void abort() => aborts++;

  final List<Map<String, Object?>> batches = [];
  final List<bool> consents = [];
  SendResult Function() next = () => const Sent();

  @override
  Future<SendResult> send(Map<String, Object?> batch) async {
    batches.add(batch);
    return next();
  }

  @override
  Future<bool> setConsent({required bool optedOut}) async {
    consents.add(optedOut);
    return true;
  }

  /// Every event in every batch sent so far.
  List<Map<String, Object?>> get sentEvents => [
    for (final b in batches)
      for (final e in (b['events'] as List)) (e as Map).cast<String, Object?>(),
  ];
}

const testInstallId = '4b0c8a1e-3f2d-4c5b-9a8e-7d6c5b4a3f21';

const testDevice = DeviceContext(
  appVersion: '1.1.0+7',
  osName: 'android',
  deviceClass: 'phone',
  locale: 'en-LK',
);

/// A real [AnalyticsClient] with a fake transport and memory stores.
/// [timers] false (the default for widget tests) means no periodic flush
/// and no persist debounce, so a test never ends with a timer pending.
AnalyticsClient newTestClient({
  FakeAnalyticsTransport? transport,
  MemoryQueueStore? store,
  MemoryAnalyticsSettings? settings,
  bool timers = false,
  int flushAt = 1 << 30,
}) => AnalyticsClient(
  transport: transport ?? FakeAnalyticsTransport(),
  store: store ?? MemoryQueueStore(),
  settings: settings ?? MemoryAnalyticsSettings(install: testInstallId),
  device: testDevice,
  flushInterval: timers ? const Duration(seconds: 30) : null,
  persistDelay: timers ? const Duration(seconds: 1) : null,
  flushAt: flushAt,
);

/// Installs a started test client as [Analytics.instance] for one test,
/// and restores the no-op afterwards.
Future<AnalyticsClient> installTestAnalytics({
  FakeAnalyticsTransport? transport,
}) async {
  final client = newTestClient(transport: transport);
  await client.start();
  Analytics.instance = client;
  addTearDown(() {
    client.dispose();
    Analytics.instance = NoopAnalytics();
  });
  return client;
}

/// What is queued, oldest first.
List<Map<String, Object?>> queued(AnalyticsClient client) =>
    client.queue.peek(1 << 20);

/// The names of what is queued, in order.
List<String> names(AnalyticsClient client) => [
  for (final e in queued(client)) e['event_name'] as String,
];

/// `event:screen` for the screen events queued, in order.
List<String> screenEvents(AnalyticsClient client) => [
  for (final e in queued(client))
    if (e['event_name'] == 'screen_viewed' || e['event_name'] == 'screen_left')
      '${e['event_name']}:${e['screen']}',
];

/// `event:step` for one flow's events queued, in order.
List<String> flowEvents(AnalyticsClient client, String flowId) => [
  for (final e in queued(client))
    if (e['flow_id'] == flowId)
      '${e['event_name']}${e['flow_step'] == null ? '' : ':${e['flow_step']}'}',
];
