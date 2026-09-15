import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/models/paged_result.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/main.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';

import 'support/scripted_meetup_service.dart';

// Counts how many times the browse endpoint is actually hit, so a test can
// assert on requests rather than on rendered output.
class _CountingMeetupService extends ScriptedMeetupService {
  _CountingMeetupService({super.openMeetups});

  int listOpenCalls = 0;
  int listParticipantsCalls = 0;

  @override
  Future<PagedResult<Meetup>> listOpenMeetups({
    IntentType? intent,
    required double viewerLat,
    required double viewerLng,
    String? cursor,
    int withinDays = 0,
  }) {
    listOpenCalls++;
    return super.listOpenMeetups(
      intent: intent,
      viewerLat: viewerLat,
      viewerLng: viewerLng,
      withinDays: withinDays,
      cursor: cursor,
    );
  }

  @override
  Future<MeetupParticipants> listMeetupParticipants(String meetupId) {
    listParticipantsCalls++;
    return super.listMeetupParticipants(meetupId);
  }
}

({IntentType? intent, double viewerLat, double viewerLng, int withinDays}) _key(
  IntentType? intent,
) => (intent: intent, viewerLat: 6.871, viewerLng: 79.908, withinDays: 28);

void main() {
  _retryPolicyTests();

  // What actually collapses the duplicate fetches is that both readers are
  // alive at the same time, not a cache with a lifetime.
  //
  // ParticipantsPage is PUSHED over the meetup detail page, so the route
  // underneath stays in the tree and ParticipantsStrip keeps watching. Two
  // overlapping listeners on one autoDispose family is one request. That was
  // not true before, because each widget called the service directly from its
  // own initState and neither could see the other.
  group('participants are fetched once for overlapping readers', () {
    test('two simultaneous listeners share one request', () async {
      final service = _CountingMeetupService();
      final container = ProviderContainer(
        overrides: [meetupServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      // The strip mounts first and stays mounted...
      final strip = container.listen(
        meetupParticipantsProvider('meetup-1'),
        (_, _) {},
      );
      await container.read(meetupParticipantsProvider('meetup-1').future);

      // ...then the page is pushed on top and reads the same family.
      final page = container.listen(
        meetupParticipantsProvider('meetup-1'),
        (_, _) {},
      );
      await container.read(meetupParticipantsProvider('meetup-1').future);

      expect(
        service.listParticipantsCalls,
        1,
        reason: 'the pushed page must reuse the strip\'s in-flight result',
      );
      strip.close();
      page.close();
    });

    test('a different meetup is a different request', () async {
      final service = _CountingMeetupService();
      final container = ProviderContainer(
        overrides: [meetupServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      await container.read(meetupParticipantsProvider('meetup-1').future);
      await container.read(meetupParticipantsProvider('meetup-2').future);
      expect(service.listParticipantsCalls, 2);
    });
  });

  // The guard that matters most: nothing here may stop new data arriving.
  group('browse data stays fresh', () {
    test('invalidate forces a fresh fetch - this is how a NEW meetup reaches '
        'the screen', () async {
      final service = _CountingMeetupService(openMeetups: const []);
      final container = ProviderContainer(
        overrides: [meetupServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      final sub = container.listen(openMeetupsProvider(_key(null)), (_, _) {});
      await container.read(openMeetupsProvider(_key(null)).future);
      expect(service.listOpenCalls, 1);

      // Pull-to-refresh and the meetup_nearby push handler both do this.
      container.invalidate(openMeetupsProvider);
      await container.read(openMeetupsProvider(_key(null)).future);
      expect(
        service.listOpenCalls,
        2,
        reason: 'invalidate must refetch, or new meetups never appear',
      );
      sub.close();
    });

    test('each filter is its own question and its own answer', () async {
      final service = _CountingMeetupService(openMeetups: const []);
      final container = ProviderContainer(
        overrides: [meetupServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      await container.read(openMeetupsProvider(_key(null)).future);
      await container.read(openMeetupsProvider(_key(IntentType.coffee)).future);
      expect(service.listOpenCalls, 2);
    });
  });
}

// A dead session must not be retried.
//
// Riverpod retries a failed provider forever with backoff, which is right for
// a flaky network and wrong for a 401: the refresh token is gone and the
// answer will never change. Observed in production on 2026-09-11 as
// /v1/meetups/active repeating every ~10s while the user looked at a skeleton.
void _retryPolicyTests() {
  group('retry policy', () {
    test('a session failure is terminal, for both service families', () {
      expect(
        retryPolicyForTest(0, const MeetupSessionExpiredException('gone')),
        isNull,
      );
      expect(
        retryPolicyForTest(0, const SessionExpiredException('gone')),
        isNull,
      );
    });

    test('a transient failure still retries, with backoff', () {
      const err = MeetupNetworkException('flaky');
      expect(retryPolicyForTest(0, err), const Duration(milliseconds: 200));
      expect(retryPolicyForTest(1, err), const Duration(milliseconds: 400));
      expect(retryPolicyForTest(3, err), const Duration(milliseconds: 1600));
    });

    test('backoff is capped rather than growing without bound', () {
      const err = MeetupNetworkException('flaky');
      expect(retryPolicyForTest(7, err), const Duration(milliseconds: 6400));
    });

    test('retries stop after the budget: an offline phone must not ask the '
        'server every 6.4 seconds for as long as the app is open', () {
      const err = MeetupOfflineException();
      expect(retryPolicyForTest(maxProviderRetries - 1, err), isNotNull);
      expect(retryPolicyForTest(maxProviderRetries, err), isNull);
      expect(retryPolicyForTest(20, err), isNull);
    });
  });
}
