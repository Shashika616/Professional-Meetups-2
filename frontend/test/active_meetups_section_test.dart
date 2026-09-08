import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
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

  /// # THE "HAPPENING NOW" CARD
  ///
  /// It is the one thing on Home that is happening right now, so it is the
  /// page's single elevated surface. Two things were wrong before: a second
  /// concurrent meetup was reachable only by swiping a card that gave no
  /// sign it could be swiped, and the card's accent was a full-bleed
  /// `candyBlue @ 10%` wash that on the light theme reads as a flat grey —
  /// disabled rather than urgent.
  group('happening-now card presentation', () {
    Meetup nowMeetup(String id, String host) => _meetup(
      id: id,
      hostFullName: host,
      windowStart: DateTime.now().subtract(const Duration(minutes: 5)),
      windowEnd: DateTime.now().add(const Duration(hours: 1)),
    );

    testWidgets('a single concurrent meetup shows no page dots', (
      tester,
    ) async {
      final service = ScriptedMeetupService(
        activeMeetups: [nowMeetup('m-1', 'Grace Hopper')],
      );

      await tester.pumpWidget(_appWith(service));
      await tester.pumpAndSettle();

      expect(find.text('Grace Hopper'), findsWidgets);
      expect(
        find.byType(PageView),
        findsNothing,
        reason: 'one card needs no pager',
      );
    });

    testWidgets(
      'two concurrent meetups get page dots — without them a second meetup '
      'is reachable only by a user who guesses the card is swipeable',
      (tester) async {
        final service = ScriptedMeetupService(
          activeMeetups: [
            nowMeetup('m-1', 'Grace Hopper'),
            nowMeetup('m-2', 'Ada Lovelace'),
          ],
        );

        await tester.pumpWidget(_appWith(service));
        await tester.pumpAndSettle();

        expect(find.byType(PageView), findsOneWidget);
        expect(
          find.bySemanticsLabel('Meetup 1 of 2'),
          findsOneWidget,
          reason:
              'the count is the information the dots carry, and it must reach '
              'a screen reader too',
        );
      },
    );

    testWidgets('swiping the card set advances the dots', (tester) async {
      final service = ScriptedMeetupService(
        activeMeetups: [
          nowMeetup('m-1', 'Grace Hopper'),
          nowMeetup('m-2', 'Ada Lovelace'),
        ],
      );

      await tester.pumpWidget(_appWith(service));
      await tester.pumpAndSettle();

      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Meetup 2 of 2'), findsOneWidget);
      expect(find.text('Ada Lovelace'), findsWidgets);
    });

    testWidgets(
      'the card is the page\'s one elevated surface, and its fill is the '
      'plain card colour — not the grey-blue wash it used to be',
      (tester) async {
        final service = ScriptedMeetupService(
          activeMeetups: [nowMeetup('m-1', 'Grace Hopper')],
        );

        await tester.pumpWidget(_appWith(service));
        await tester.pumpAndSettle();

        final elevated = tester
            .widgetList<FlatCard>(find.byType(FlatCard))
            .where((c) => c.elevated)
            .toList();
        expect(
          elevated.length,
          1,
          reason: 'exactly one — if everything is elevated, nothing is',
        );
        expect(
          elevated.single.tint,
          isNull,
          reason:
              'the accent is a solid left bar now; a low-alpha tint over the '
              'whole card was what made it read as disabled',
        );
      },
    );
  });
}
