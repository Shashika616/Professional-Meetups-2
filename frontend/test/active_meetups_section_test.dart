import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/features/home/widgets/active_meetups_section.dart';
import 'package:professional_connections_platform/features/meetups/widgets/rating_prompt.dart';

import 'support/scripted_meetup_service.dart';

Meetup _meetup({
  required String id,
  required String hostFullName,
  required DateTime windowStart,
  required DateTime windowEnd,
}) => Meetup(
  id: id,
  hostUserId: 'host-$id',
  hostFullName: hostFullName,
  hostTrustLevel: 2,
  intent: IntentType.coffee,
  windowStart: windowStart,
  windowEnd: windowEnd,
  locationLat: 6.9271,
  locationLng: 79.8612,
  locationLabel: 'Colombo Fort Cafe',
  capacity: 4,
  acceptedCount: 1,
  status: MeetupStatus.open,
  createdAt: DateTime.now(),
);

Widget _appWith(MeetupService service) {
  return ProviderScope(
    overrides: [meetupServiceProvider.overrideWithValue(service)],
    child: const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: ActiveMeetupsSection()),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'the persistent card only appears for a meetup within its eligible '
    'window ([windowStart-30min, windowEnd]), not one starting well outside it',
    (tester) async {
      final now = DateTime.now();
      final tooFarOut = _meetup(
        id: 'far',
        hostFullName: 'Far Off Host',
        windowStart: now.add(const Duration(hours: 2)),
        windowEnd: now.add(const Duration(hours: 4)),
      );
      final service = ScriptedMeetupService(activeMeetups: [tooFarOut]);

      await tester.pumpWidget(_appWith(service));
      await tester.pumpAndSettle();

      // Still listed in the plain "Active Meetups" list...
      expect(find.text('Far Off Host'), findsOneWidget);
      // ...but not promoted to the "HAPPENING NOW" persistent card.
      expect(find.text('HAPPENING NOW'), findsNothing);
    },
  );

  testWidgets('the persistent card appears once a meetup enters its 30-minute '
      'pre-window lead time', (tester) async {
    final now = DateTime.now();
    final startingSoon = _meetup(
      id: 'soon',
      hostFullName: 'Starting Soon Host',
      windowStart: now.add(const Duration(minutes: 10)),
      windowEnd: now.add(const Duration(hours: 2)),
    );
    final service = ScriptedMeetupService(activeMeetups: [startingSoon]);

    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    expect(find.text('HAPPENING NOW'), findsOneWidget);
    expect(find.text('Starting Soon Host'), findsWidgets);
  });

  testWidgets(
    'two concurrently-eligible meetups render the persistent card as a '
    'swipeable PageView',
    (tester) async {
      final now = DateTime.now();
      final first = _meetup(
        id: 'first',
        hostFullName: 'First Host',
        windowStart: now.add(const Duration(minutes: 5)),
        windowEnd: now.add(const Duration(hours: 1)),
      );
      final second = _meetup(
        id: 'second',
        hostFullName: 'Second Host',
        windowStart: now.subtract(const Duration(minutes: 10)),
        windowEnd: now.add(const Duration(hours: 2)),
      );
      final service = ScriptedMeetupService(activeMeetups: [first, second]);

      await tester.pumpWidget(_appWith(service));
      await tester.pumpAndSettle();

      expect(find.byType(PageView), findsOneWidget);
      final pageView = tester.widget<PageView>(find.byType(PageView));
      expect(pageView.controller?.initialPage ?? 0, 0);
    },
  );

  testWidgets(
    'once windowEnd passes, the card converts in place to the existing '
    'RatingPrompt component instead of a second prompt UI',
    (tester) async {
      final now = DateTime.now();
      final justEnded = _meetup(
        id: 'ended',
        hostFullName: 'Just Ended Host',
        windowStart: now.subtract(const Duration(hours: 1)),
        windowEnd: now.subtract(const Duration(minutes: 1)),
      );
      final service = ScriptedMeetupService(
        activeMeetups: [justEnded],
        ratableParticipants: [
          const RatableParticipant(
            userId: 'host-ended',
            fullName: 'Just Ended Host',
            trustLevel: 2,
          ),
        ],
      );

      await tester.pumpWidget(_appWith(service));
      await tester.pumpAndSettle();

      expect(find.byType(RatingPrompt), findsOneWidget);
      expect(find.text('RATE WHO YOU MET'), findsOneWidget);
    },
  );

  testWidgets(
    'the plain ACTIVE MEETUPS row shows COMPLETED for a windowEnd-passed '
    'meetup, agreeing with the persistent card above it flipping to '
    'RatingPrompt, instead of a stale OPEN badge (ADR-030, round-9: the '
    'reconciled persistent-card/list-badge inconsistency)',
    (tester) async {
      final now = DateTime.now();
      final justEnded = _meetup(
        id: 'ended-2',
        hostFullName: 'Another Ended Host',
        windowStart: now.subtract(const Duration(hours: 1)),
        windowEnd: now.subtract(const Duration(minutes: 1)),
      );
      final service = ScriptedMeetupService(activeMeetups: [justEnded]);

      await tester.pumpWidget(_appWith(service));
      await tester.pumpAndSettle();

      // The persistent card converted to RatingPrompt (unchanged behavior)...
      expect(find.byType(RatingPrompt), findsOneWidget);
      // ...and the same meetup's row below now agrees: COMPLETED, not the
      // server's still-open status (the poller hasn't ticked yet in this
      // fixture — status stays MeetupStatus.open, ScriptedMeetupService
      // never flips it).
      expect(find.text('COMPLETED'), findsOneWidget);
      expect(find.text('OPEN'), findsNothing);
    },
  );

  testWidgets(
    'the 30s Timer.periodic tick only recomputes local state — it must '
    'NOT call the network (ADR-030, round-9: real periodic polling was '
    'considered and deliberately rejected on cost grounds; this is a '
    'regression guard so a future pass can\'t reintroduce it silently)',
    (tester) async {
      final now = DateTime.now();
      final meetup = _meetup(
        id: 'm1',
        hostFullName: 'Steady Host',
        windowStart: now.subtract(const Duration(minutes: 5)),
        windowEnd: now.add(const Duration(hours: 1)),
      );
      final service = ScriptedMeetupService(activeMeetups: [meetup]);

      await tester.pumpWidget(_appWith(service));
      await tester.pumpAndSettle();

      expect(service.listActiveMeetupsCallCount, 1);

      // Let three 30s ticks fire — well past a single tick, to rule out an
      // off-by-one rather than a genuine "never refetches" guarantee.
      await tester.pump(const Duration(seconds: 31));
      await tester.pump(const Duration(seconds: 31));
      await tester.pump(const Duration(seconds: 31));

      expect(
        service.listActiveMeetupsCallCount,
        1,
        reason:
            'the periodic timer must only setState() a local recompute, '
            'never re-invoke listActiveMeetups()',
      );
    },
  );
}
