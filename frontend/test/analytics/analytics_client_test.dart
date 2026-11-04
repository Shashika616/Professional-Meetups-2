import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/analytics/analytics_client.dart';
import 'package:professional_connections_platform/core/analytics/analytics_queue.dart';
import 'package:professional_connections_platform/core/analytics/analytics_transport.dart';
import 'package:professional_connections_platform/core/analytics/event_names.g.dart';

import '../support/analytics_harness.dart';

void main() {
  group('queue', () {
    test('holds at most 500 events and drops the oldest', () {
      final queue = AnalyticsQueue(store: MemoryQueueStore());
      for (var i = 0; i < 520; i++) {
        queue.add({'event_id': 'e$i'});
      }
      expect(queue.length, 500);
      expect(queue.peek(1).single['event_id'], 'e20');
      expect(queue.droppedOldest, 20);
    });

    test('survives a restart', () async {
      final store = MemoryQueueStore();
      final settings = MemoryAnalyticsSettings(install: testInstallId);
      final first = newTestClient(store: store, settings: settings);
      await first.start();
      first.cta(AnalyticsCta.buyCredits);
      await first.queue.persist();
      final ids = [for (final e in queued(first)) e['event_id']];

      // A new process: same storage, nothing in memory.
      final second = newTestClient(store: store, settings: settings);
      await second.start();
      final reloaded = [for (final e in queued(second)) e['event_id']];
      expect(reloaded.take(ids.length), ids);
      expect(names(second).sublist(ids.length), [
        AnalyticsEvent.sessionStarted,
        AnalyticsEvent.appOpened,
      ]);
      expect(second.installId, testInstallId);
    });

    test('a corrupt stored entry is skipped, not fatal', () async {
      final store = MemoryQueueStore()
        ..events = ['not json', '{"event_id":"ok"}'];
      final queue = AnalyticsQueue(store: store);
      await queue.load();
      expect(queue.peek(5).map((e) => e['event_id']), ['ok']);
    });
  });

  group('flushing', () {
    test('at 20 events, every 30 seconds, and on going to the background', () {
      fakeAsync((async) {
        final transport = FakeAnalyticsTransport();
        final client = newTestClient(
          transport: transport,
          timers: true,
          flushAt: 20,
        );
        client.start();
        async.flushMicrotasks();
        expect(transport.batches, isEmpty);

        // 2 already queued (session_started, app_opened); 18 more is 20.
        for (var i = 0; i < 18; i++) {
          client.cta(AnalyticsCta.openMap);
        }
        async.flushMicrotasks();
        expect(transport.batches, hasLength(1));
        expect(transport.sentEvents, hasLength(20));
        expect(client.queue.isEmpty, isTrue);

        client.cta(AnalyticsCta.openMap);
        async.elapse(const Duration(seconds: 29));
        expect(transport.batches, hasLength(1));
        async.elapse(const Duration(seconds: 1));
        expect(transport.batches, hasLength(2));

        client.cta(AnalyticsCta.openMap);
        client.lifecycleChanged(AppLifecycleState.paused);
        async.flushMicrotasks();
        expect(transport.batches, hasLength(3));
        client.dispose();
      });
    });

    test('a batch carries the coarse context and at most 50 events', () {
      fakeAsync((async) {
        final transport = FakeAnalyticsTransport();
        final client = newTestClient(transport: transport);
        client.start();
        async.flushMicrotasks();
        for (var i = 0; i < 60; i++) {
          client.cta(AnalyticsCta.openMap);
        }
        client.flush();
        async.flushMicrotasks();
        expect(transport.batches.map((b) => (b['events'] as List).length), [
          50,
          12,
        ]);
        final batch = transport.batches.first;
        expect(batch['install_id'], testInstallId);
        expect(batch['app_version'], '1.1.0+7');
        expect(batch['os_name'], 'android');
        expect(batch['device_class'], 'phone');
        expect(batch['locale'], 'en-LK');
      });
    });

    test('offline: nothing is lost, and sending waits for the backoff', () {
      fakeAsync((async) {
        final transport = FakeAnalyticsTransport()
          ..next = () => const RetryLater();
        final client = newTestClient(transport: transport);
        client.start();
        async.flushMicrotasks();
        client.cta(AnalyticsCta.openMap);
        client.flush();
        async.flushMicrotasks();
        expect(transport.batches, hasLength(1));
        expect(client.queue.length, 3, reason: 'held, not dropped');

        // Asked again straight away: the backoff holds it (30 s).
        client.flush();
        async.flushMicrotasks();
        expect(transport.batches, hasLength(1));
        async.elapse(const Duration(seconds: 31));
        client.flush();
        async.flushMicrotasks();
        expect(transport.batches, hasLength(2));

        // Second failure in a row: a minute.
        async.elapse(const Duration(seconds: 31));
        client.flush();
        async.flushMicrotasks();
        expect(transport.batches, hasLength(2));
        async.elapse(const Duration(seconds: 30));
        transport.next = () => const Sent();
        client.flush();
        async.flushMicrotasks();
        expect(transport.batches, hasLength(3));
        expect(client.queue.isEmpty, isTrue);
        expect(transport.sentEvents, hasLength(3 * 3 - 0));
      });
    });

    test('429 waits for Retry-After', () {
      fakeAsync((async) {
        final transport = FakeAnalyticsTransport()
          ..next = () => const RetryLater(after: Duration(minutes: 2));
        final client = newTestClient(transport: transport);
        client.start();
        async.flushMicrotasks();
        client.flush();
        async.flushMicrotasks();
        transport.next = () => const Sent();
        async.elapse(const Duration(seconds: 119));
        client.flush();
        async.flushMicrotasks();
        expect(transport.batches, hasLength(1));
        async.elapse(const Duration(seconds: 1));
        client.flush();
        async.flushMicrotasks();
        expect(transport.batches, hasLength(2));
      });
    });

    test('a batch the server refuses for good is dropped, not retried', () {
      fakeAsync((async) {
        final transport = FakeAnalyticsTransport()
          ..next = () => const Refused();
        final client = newTestClient(transport: transport);
        client.start();
        async.flushMicrotasks();
        client.flush();
        async.flushMicrotasks();
        expect(client.queue.isEmpty, isTrue);
      });
    });
  });

  group('opting out', () {
    test(
      'clears the queue, stops recording and sending, tells the server',
      () async {
        final store = MemoryQueueStore();
        final transport = FakeAnalyticsTransport();
        final settings = MemoryAnalyticsSettings(install: testInstallId);
        final client = newTestClient(
          transport: transport,
          store: store,
          settings: settings,
        );
        await client.start();
        client.cta(AnalyticsCta.openMap);
        await client.setOptedOut(true);
        expect(client.queue.isEmpty, isTrue);
        expect(store.events, isEmpty);
        expect(settings.opted, isTrue);
        expect(transport.consents, [true]);

        client.cta(AnalyticsCta.openMap);
        await client.flush();
        expect(client.queue.isEmpty, isTrue);
        expect(transport.batches, isEmpty);

        // The choice survives a restart.
        final again = newTestClient(
          transport: transport,
          store: store,
          settings: settings,
        );
        await again.start();
        expect(again.optedOut, isTrue);
        expect(again.queue.isEmpty, isTrue);

        await again.setOptedOut(false);
        again.cta(AnalyticsCta.openMap);
        expect(names(again), [AnalyticsEvent.ctaTapped]);
        expect(transport.consents, [true, false]);
      },
    );

    test('the server switch and the sample rate stop recording too', () async {
      final client = newTestClient();
      await client.start();
      client.applyRemoteConfig(enabled: false, sampleRate: 100);
      expect(client.queue.isEmpty, isTrue);
      client.cta(AnalyticsCta.openMap);
      expect(client.queue.isEmpty, isTrue);

      client.applyRemoteConfig(enabled: true, sampleRate: 100);
      client.cta(AnalyticsCta.openMap);
      expect(client.queue.length, 1);

      // The install's bucket: its first 32 bits, mod 100. Inside a rate
      // above it, outside a rate at or below it, and stable either way.
      final bucket = int.parse(testInstallId.substring(0, 8), radix: 16) % 100;
      client.applyRemoteConfig(enabled: true, sampleRate: bucket);
      client.cta(AnalyticsCta.openMap);
      expect(client.queue.isEmpty, isTrue);
      client.applyRemoteConfig(enabled: true, sampleRate: bucket + 1);
      client.cta(AnalyticsCta.openMap);
      expect(client.queue.length, 1);
    });
  });

  group('sessions', () {
    test(
      'an event recorded while start() is still loading has the session',
      () async {
        final client = newTestClient();
        final starting = client.start();
        // The first screen appears before the stored queue has loaded.
        client.cta(AnalyticsCta.openMap);
        await starting;
        final sessions = {for (final e in queued(client)) e['session_id']};
        expect(sessions, hasLength(1));
        expect(sessions.single, client.sessionId);
        expect(client.sessionId, isNotEmpty);
      },
    );

    test('a new session after 30 minutes in the background, not before', () {
      fakeAsync((async) {
        final client = newTestClient();
        client.start();
        async.flushMicrotasks();
        final first = client.sessionId;

        client.lifecycleChanged(AppLifecycleState.paused);
        async.elapse(const Duration(minutes: 29));
        client.lifecycleChanged(AppLifecycleState.resumed);
        expect(client.sessionId, first);

        async.elapse(const Duration(minutes: 5));
        client.lifecycleChanged(AppLifecycleState.paused);
        async.elapse(const Duration(minutes: 31));
        client.lifecycleChanged(AppLifecycleState.resumed);
        expect(client.sessionId, isNot(first));

        final ended = queued(
          client,
        ).firstWhere((e) => e['event_name'] == AnalyticsEvent.sessionEnded);
        expect(ended['session_id'], first);
        // From the start to the moment it went away: 29 + 5 minutes.
        expect(
          (ended['attributes'] as Map)[AnalyticsAttribute.durationMs],
          const Duration(minutes: 34).inMilliseconds,
        );
        expect(names(client).sublist(names(client).length - 3), [
          AnalyticsEvent.sessionEnded,
          AnalyticsEvent.sessionStarted,
          AnalyticsEvent.appForegrounded,
        ]);
      });
    });
  });

  group('leaving the phone (N1-D5) and opting out (N1-D8)', () {
    test('rotating sends what is queued, then takes a new id', () async {
      final transport = FakeAnalyticsTransport();
      final settings = MemoryAnalyticsSettings(install: testInstallId);
      final client = newTestClient(transport: transport, settings: settings);
      addTearDown(client.dispose);
      await client.start();

      await client.rotateInstallId();
      expect(transport.batches.single['install_id'], testInstallId);
      expect(client.installId, isNot(testInstallId));
      expect(client.installId, hasLength(36));
      expect(settings.install, client.installId);

      client.record(AnalyticsEvent.appOpened);
      await client.flush();
      expect(transport.batches.last['install_id'], client.installId);
    });

    test('what could not be sent does not go out under the new id', () async {
      final transport = FakeAnalyticsTransport()
        ..next = () => const RetryLater();
      final client = newTestClient(transport: transport);
      addTearDown(client.dispose);
      await client.start();
      await client.rotateInstallId();
      expect(client.queue.isEmpty, isTrue);
    });

    test('opting out stops a batch on its way, and no other follows', () async {
      final gate = Completer<SendResult>();
      final transport = _HeldTransport(gate);
      final client = newTestClient(transport: transport);
      addTearDown(client.dispose);
      await client.start();
      unawaited(client.flush());
      await pumpEventQueue();
      expect(transport.batches, hasLength(1));

      await client.setOptedOut(true);
      expect(transport.aborts, 1);
      gate.complete(const RetryLater());
      await pumpEventQueue();
      expect(transport.batches, hasLength(1));
      expect(client.queue.isEmpty, isTrue);
    });
  });
}

class _HeldTransport extends FakeAnalyticsTransport {
  _HeldTransport(this.gate);

  final Completer<SendResult> gate;

  @override
  Future<SendResult> send(Map<String, Object?> batch) {
    batches.add(batch);
    return gate.future;
  }
}
