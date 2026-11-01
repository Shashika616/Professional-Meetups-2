import 'dart:async';
import 'dart:io' show SocketException;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:professional_connections_platform/core/analytics/analytics.dart';
import 'package:professional_connections_platform/core/analytics/event_names.g.dart';
import 'package:professional_connections_platform/core/services/client_info_http_client.dart';

import '../support/analytics_harness.dart';

Map<String, Object?> _attrs(Map<String, Object?> e) =>
    (e['attributes'] as Map).cast<String, Object?>();

void main() {
  test(
    'error statuses and lost connections are reported by route only',
    () async {
      final analytics = await installTestAnalytics();
      analytics.queue.clear();
      final client = ClientInfoHttpClient(
        MockClient((request) async {
          if (request.url.path.endsWith('/down')) {
            throw const SocketException('no route');
          }
          final status = request.url.path.endsWith('/missing') ? 404 : 200;
          return http.Response('', status);
        }),
      );
      await client.get(Uri.parse('https://api.example/v1/meetups/mine'));
      await client.get(
        Uri.parse(
          'https://api.example/v1/meetups/0192f0a4-7b1c-7d3e-8f00-0123456789ab/missing',
        ),
      );
      await expectLater(
        client.post(Uri.parse('https://api.example/v1/sos/down')),
        throwsA(isA<SocketException>()),
      );

      final errors = queued(analytics)
          .where((e) => e['event_name'] == AnalyticsEvent.apiError)
          .map(_attrs)
          .toList();
      expect(errors, [
        {
          AnalyticsAttribute.route: 'get:v1.meetups.:id.missing',
          AnalyticsAttribute.statusClass: AnalyticsValue.apiErrorStatusClass4xx,
        },
        {
          AnalyticsAttribute.route: 'post:v1.sos.down',
          AnalyticsAttribute.statusClass:
              AnalyticsValue.apiErrorStatusClassNetwork,
        },
      ]);
    },
  );

  test('no answer within 15 seconds is a request_timeout', () {
    fakeAsync((async) {
      final analytics = newTestClient();
      analytics.start();
      async.flushMicrotasks();
      Analytics.instance = analytics;
      addTearDown(() => Analytics.instance = NoopAnalytics());
      final never = Completer<http.StreamedResponse>();
      final client = ClientInfoHttpClient(
        MockClient.streaming((request, body) => never.future),
      );
      unawaited(
        client
            .get(Uri.parse('https://api.example/v1/meetups/active'))
            .then((_) {}, onError: (_) {}),
      );
      async.elapse(const Duration(seconds: 14));
      expect(names(analytics), isNot(contains(AnalyticsEvent.requestTimeout)));
      async.elapse(const Duration(seconds: 1));
      final timeouts = queued(
        analytics,
      ).where((e) => e['event_name'] == AnalyticsEvent.requestTimeout);
      expect(timeouts.map(_attrs), [
        {AnalyticsAttribute.route: 'get:v1.meetups.active'},
      ]);
    });
  });

  test('under the no-op analytics nothing is watched (no timers in tests)', () {
    fakeAsync((async) {
      expect(ApiActivity.active, isFalse);
      // A request still in flight: a watch timer would be pending now.
      final never = Completer<http.StreamedResponse>();
      final client = ClientInfoHttpClient(
        MockClient.streaming((request, body) => never.future),
      );
      unawaited(
        client
            .get(Uri.parse('https://api.example/v1/x'))
            .then((_) {}, onError: (_) {}),
      );
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
    });
  });
}
