import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/analytics/analytics.dart';
import 'package:professional_connections_platform/core/analytics/event_names.g.dart';

import '../support/analytics_harness.dart';

/// What the ingest accepts (docs/api/analytics.md), and nothing else.
const _batchKeys = {
  'install_id',
  'app_version',
  'os_name',
  'os_version',
  'device_class',
  'locale',
  'events',
};
const _eventKeys = {
  'event_id',
  'event_name',
  'schema_version',
  'occurred_at',
  'session_id',
  'screen',
  'flow_id',
  'flow_step',
  'attributes',
};

final _identifier = RegExp(r'^[a-z0-9][a-z0-9_.:-]*$');
final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

void main() {
  test(
    'every event type serialises to the allowed envelope and nothing else',
    () async {
      final transport = FakeAnalyticsTransport();
      final client = await installTestAnalytics(transport: transport);

      // One of every app event, with every attribute it may carry.
      final sample = <String, Attributes>{
        AnalyticsEvent.appOpened: {AnalyticsAttribute.coldStart: true},
        AnalyticsEvent.sessionEnded: {AnalyticsAttribute.durationMs: 1000},
        AnalyticsEvent.screenLeft: {AnalyticsAttribute.durationMs: 1200},
        AnalyticsEvent.ctaTapped: {AnalyticsAttribute.cta: AnalyticsCta.sos},
        AnalyticsEvent.searchPerformed: {
          AnalyticsAttribute.resultCount: 4,
          AnalyticsAttribute.filterCount: 1,
        },
        AnalyticsEvent.filterChanged: {
          AnalyticsAttribute.filter: 'intent_coffee',
          AnalyticsAttribute.active: true,
        },
        AnalyticsEvent.toggleChanged: {
          AnalyticsAttribute.toggle: 'analytics',
          AnalyticsAttribute.value: false,
        },
        AnalyticsEvent.flowStepCompleted: {AnalyticsAttribute.durationMs: 5},
        AnalyticsEvent.flowCompleted: {AnalyticsAttribute.durationMs: 5},
        AnalyticsEvent.flowAbandoned: {
          AnalyticsAttribute.reason: AnalyticsValue.flowAbandonedReasonBack,
        },
        AnalyticsEvent.errorShown: {
          AnalyticsAttribute.kind: 'load_failed_offline',
        },
        AnalyticsEvent.rageTap: {AnalyticsAttribute.taps: 3},
        AnalyticsEvent.longDwell: {AnalyticsAttribute.durationMs: 60000},
        AnalyticsEvent.creditsInsufficientShown: {
          AnalyticsAttribute.requiredCredits: 14,
        },
      };
      for (final name in analyticsEventVersions.keys) {
        client.record(
          name,
          attributes: sample[name] ?? const {},
          screen: AnalyticsScreen.home,
          flowId: AnalyticsFlow.scheduleMeetup,
          flowStep: AnalyticsFlowStep.scheduleMeetupTiming,
        );
      }
      // The HTTP friction events, from URLs that carry ids, an email and a
      // query string: none of that may come through.
      ApiActivity.status(
        'GET',
        Uri.parse(
          'https://api.example/v1/meetups/0192f0a4-7b1c-7d3e-8f00-0123456789ab/requests?lat=6.9271&lng=79.8612',
        ),
        500,
      );
      ApiActivity.status(
        'POST',
        Uri.parse('https://api.example/v1/users/jane.doe@example.com/verify'),
        404,
      );
      ApiActivity.failed(
        'GET',
        Uri.parse('https://api.example/v1/users/12345'),
        timeout: true,
      );
      // The analytics endpoints never report on themselves.
      ApiActivity.status(
        'POST',
        Uri.parse('https://api.example/v1/analytics/events'),
        500,
      );

      await client.flush();
      expect(transport.batches, isNotEmpty);
      final names = <String>{};
      for (final batch in transport.batches) {
        expect(batch.keys.toSet().difference(_batchKeys), isEmpty);
        expect(_uuid.hasMatch(batch['install_id'] as String), isTrue);
        final json = jsonEncode(batch);
        for (final forbidden in [
          '@',
          'jane',
          'example.com',
          '6.9271',
          '79.8612',
          'lat=',
          'http',
          '"user_id":',
          '"email":',
          '"phone":',
          '"name":',
          '"latitude":',
          '"longitude":',
          'receipt',
          'token',
        ]) {
          expect(
            json.contains(forbidden),
            isFalse,
            reason: 'found $forbidden in $json',
          );
        }
        for (final event
            in (batch['events'] as List).cast<Map<String, Object?>>()) {
          names.add(event['event_name'] as String);
          expect(
            event.keys.toSet().difference(_eventKeys),
            isEmpty,
            reason: '$event',
          );
          expect(_uuid.hasMatch(event['event_id'] as String), isTrue);
          expect((event['event_id'] as String)[14], '7', reason: 'UUIDv7');
          for (final key in ['screen', 'flow_id', 'flow_step']) {
            final v = event[key];
            if (v != null) {
              expect(
                _identifier.hasMatch(v as String),
                isTrue,
                reason: '$key=$v',
              );
            }
          }
          final attributes = (event['attributes'] as Map)
              .cast<String, Object?>();
          expect(attributes.length, lessThanOrEqualTo(20));
          for (final MapEntry(:key, :value) in attributes.entries) {
            expect(_identifier.hasMatch(key), isTrue);
            if (value is String) {
              expect(value.length, lessThanOrEqualTo(100));
              expect(
                _identifier.hasMatch(value),
                isTrue,
                reason: '$key=$value',
              );
            } else {
              expect(
                value is bool || value is int,
                isTrue,
                reason: '$key=$value',
              );
            }
          }
        }
      }
      expect(names, containsAll(analyticsEventVersions.keys));
      expect(
        transport.sentEvents
            .where(
              (e) =>
                  e['event_name'] == AnalyticsEvent.apiError &&
                  (e['attributes'] as Map).isNotEmpty,
            )
            .map((e) => (e['attributes'] as Map)[AnalyticsAttribute.route]),
        ['get:v1.meetups.:id.requests', 'post:v1.users.:value.verify'],
      );
      expect(
        transport.sentEvents
            .where(
              (e) =>
                  e['event_name'] == AnalyticsEvent.requestTimeout &&
                  (e['attributes'] as Map).isNotEmpty,
            )
            .map((e) => (e['attributes'] as Map)[AnalyticsAttribute.route]),
        ['get:v1.users.:id'],
      );
    },
  );

  test('route templates never carry ids, emails or queries', () {
    expect(
      routeTemplate('GET', Uri.parse('https://x/v1/meetups/mine?page=2')),
      'get:v1.meetups.mine',
    );
    expect(
      routeTemplate('PUT', Uri.parse('https://x/v1/analytics/consent')),
      'put:v1.analytics.consent',
    );
    expect(
      routeTemplate('GET', Uri.parse('https://x/c/AbC123tokenXYZ')),
      'get:c.:value',
    );
  });
}
