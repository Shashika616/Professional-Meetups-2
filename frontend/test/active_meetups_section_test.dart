import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/features/home/widgets/active_meetups_section.dart';
import 'package:professional_connections_platform/features/meetups/review/experience_scale.dart';
import 'package:professional_connections_platform/features/meetups/review/meetup_review_page.dart';

import 'support/scripted_meetup_service.dart';

Meetup _meetup({
  required String id,
  required String hostFullName,
  required DateTime windowStart,
  required DateTime windowEnd,
  String locationLabel = 'Colombo Fort Cafe',
  MeetupStatus status = MeetupStatus.open,
  String? cancellationReason,
  bool isHostedByMe = false,
  MeetupRequestStatus? myRequestStatus,
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
  locationLabel: locationLabel,
  capacity: 4,
  acceptedCount: 1,
  status: status,
  cancellationReason: cancellationReason,
  isHostedByMe: isHostedByMe,
  myRequestStatus: myRequestStatus,
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
    'the carousel grows to fit a long address instead of overflowing — its '
    'height comes from the cards, not a constant (regression: a fixed 176 '
    'overflowed by 5px the moment an address wrapped)',
    (tester) async {
      final now = DateTime.now();
      const longAddress =
          'Ellis Street & Stockton Street, Ellis Street, Union Square, '
          'San Francisco, California, United States of America';
      // Two FINISHED meetups: the review deck is a carousel just like the
      // live one, and it is the one that carries the long address here.
      // (A finished and a live meetup no longer share a deck.)
      final first = _meetup(
        id: 'first',
        hostFullName: 'First Host',
        windowStart: now.subtract(const Duration(minutes: 40)),
        windowEnd: now.subtract(const Duration(minutes: 1)),
        locationLabel: longAddress,
      );
      final second = _meetup(
        id: 'second',
        hostFullName: 'Second Host',
        windowStart: now.subtract(const Duration(hours: 2)),
        windowEnd: now.subtract(const Duration(minutes: 5)),
      );
      final service = ScriptedMeetupService(activeMeetups: [first, second]);

      await tester.pumpWidget(_appWith(service));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(PageView), findsOneWidget);
      final pageHeight = tester.getSize(find.byType(PageView)).height;
      // Tall enough for a wrapped address plus the review prompt.
      expect(pageHeight, greaterThan(176));
    },
  );

  testWidgets('once windowEnd passes, the card asks for a review — keeping the '
      "meetup's own identity, not swapping itself for a bare star picker", (
    tester,
  ) async {
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

    expect(find.text('Share your thoughts about this meetup'), findsOneWidget);
    // The card no longer opens the rating UI inline. A naked star picker
    // with no context does not say which meetup it is about or what
    // pressing it commits you to — the review is its own screen now.
    expect(
      find.text('RATE WHO YOU MET'),
      findsNothing,
      reason: 'the ratings step lives inside the review flow',
    );
  });

  testWidgets('finishing the review takes the card off Home — without a '
      'manual refresh', (tester) async {
    final now = DateTime.now();
    final justEnded = _meetup(
      id: 'ended-refresh',
      hostFullName: 'Just Ended Host',
      windowStart: now.subtract(const Duration(hours: 1)),
      windowEnd: now.subtract(const Duration(minutes: 1)),
    );
    late final ScriptedMeetupService service;
    service = ScriptedMeetupService(activeMeetups: [justEnded])
      // What the real server does: a reviewed meetup stops being returned.
      ..onSubmitReview = () => service.activeMeetups = const [];

    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Share your thoughts about this meetup'));
    await tester.pumpAndSettle();

    // The picture above is full-width now, so the slider can sit below a
    // bare test viewport — scroll it in before reading its rect.
    await tester.ensureVisible(find.byType(ExperienceSlider));
    await tester.pumpAndSettle();
    final slider = tester.getRect(find.byType(ExperienceSlider));
    await tester.tapAt(Offset(slider.center.dx, slider.center.dy));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('SUBMIT'));
    await tester.tap(find.text('SUBMIT'));
    await tester.pumpAndSettle();

    expect(service.submitReviewCallCount, 1);
    expect(
      find.text('Share your thoughts about this meetup'),
      findsNothing,
      reason: 'the card must not survive the review that completed it',
    );
  });

  testWidgets('the review card names WHICH meetup it is asking about — host, '
      'time and place, not just the ask', (tester) async {
    final now = DateTime.now();
    final justEnded = _meetup(
      id: 'ended-details',
      hostFullName: 'Grace Hopper',
      windowStart: now.subtract(const Duration(hours: 2)),
      windowEnd: now.subtract(const Duration(minutes: 5)),
    );
    final service = ScriptedMeetupService(activeMeetups: [justEnded]);

    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    // Scoped to the CARD. The host name also appears in the ACTIVE MEETUPS
    // row below, so an unscoped finder would pass even with the card's own
    // details deleted — which is exactly what a control run showed.
    final card = find.ancestor(
      of: find.text('Share your thoughts about this meetup'),
      matching: find.byType(FlatCard),
    );
    expect(card, findsWidgets);

    Finder onCard(String text) =>
        find.descendant(of: card.first, matching: find.text(text));

    // It used to show the intent and the ask and nothing else, so someone
    // with two finished meetups in the deck could not tell the cards apart
    // or know what they were about to rate.
    expect(onCard('Grace Hopper'), findsOneWidget);
    expect(onCard('Colombo Fort Cafe'), findsOneWidget);
    expect(onCard(justEnded.formattedWindow), findsOneWidget);
    expect(onCard('REVIEW'), findsOneWidget);
  });

  testWidgets('two finished meetups are told apart by their own details', (
    tester,
  ) async {
    final now = DateTime.now();
    final service = ScriptedMeetupService(
      activeMeetups: [
        _meetup(
          id: 'ended-a',
          hostFullName: 'Grace Hopper',
          windowStart: now.subtract(const Duration(hours: 2)),
          windowEnd: now.subtract(const Duration(minutes: 5)),
        ),
        _meetup(
          id: 'ended-b',
          hostFullName: 'Ada Lovelace',
          windowStart: now.subtract(const Duration(hours: 5)),
          windowEnd: now.subtract(const Duration(hours: 3)),
        ),
      ],
    );

    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    // Each card names its own host, so the two are distinguishable in the
    // deck rather than being two identical prompts.
    final cards = find.ancestor(
      of: find.text('Share your thoughts about this meetup'),
      matching: find.byType(FlatCard),
    );
    expect(
      find.descendant(of: cards.first, matching: find.text('Grace Hopper')),
      findsOneWidget,
    );
  });

  testWidgets('tapping the review card opens the review flow', (tester) async {
    final now = DateTime.now();
    final justEnded = _meetup(
      id: 'ended-tap',
      hostFullName: 'Just Ended Host',
      windowStart: now.subtract(const Duration(hours: 1)),
      windowEnd: now.subtract(const Duration(minutes: 1)),
    );
    final service = ScriptedMeetupService(activeMeetups: [justEnded]);

    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Share your thoughts about this meetup'));
    await tester.pumpAndSettle();

    expect(find.byType(MeetupReviewPage), findsOneWidget);
    expect(find.text('How was your experience?'), findsOneWidget);
  });

  testWidgets('a windowEnd-passed meetup moves to WAITING FOR YOUR REVIEW '
      'and leaves the ACTIVE MEETUPS list, so nothing on Home reads as '
      'still live once it is over (ADR-030 reconciliation, reshaped: three '
      'decks instead of one deck plus greyed rows)', (tester) async {
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

    expect(find.text('WAITING FOR YOUR REVIEW'), findsOneWidget);
    expect(find.text('Share your thoughts about this meetup'), findsOneWidget);
    expect(find.text('HAPPENING NOW'), findsNothing);
    // Nothing is live, so there is no Active Meetups list at all; the
    // finished meetup is named exactly once, on its review card.
    expect(find.text('ACTIVE MEETUPS'), findsNothing);
    expect(find.text('Another Ended Host'), findsOneWidget);
    // No row edge is painted live.
    final edges = tester
        .widgetList<Container>(
          find.descendant(
            of: find.byType(ActiveMeetupsSection),
            matching: find.byType(Container),
          ),
        )
        .where((c) => c.constraints?.maxWidth == 4)
        .map((c) => c.color)
        .toList();
    expect(edges, isNot(contains(AppPalette.verified)));
    expect(find.text('COMPLETED'), findsNothing);
    expect(find.text('OPEN'), findsNothing);
  });

  testWidgets('every card says who hosts and where the viewer stands: a '
      'live meetup the viewer joined, and one they host', (tester) async {
    final now = DateTime.now();
    final joined = _meetup(
      id: 'joined',
      hostFullName: 'Grace Hopper',
      windowStart: now.subtract(const Duration(minutes: 5)),
      windowEnd: now.add(const Duration(hours: 1)),
      myRequestStatus: MeetupRequestStatus.accepted,
    );
    final mine = _meetup(
      id: 'mine',
      hostFullName: 'Me Myself',
      windowStart: now.add(const Duration(hours: 3)),
      windowEnd: now.add(const Duration(hours: 4)),
      isHostedByMe: true,
    );
    final service = ScriptedMeetupService(activeMeetups: [joined, mine]);

    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    // The joined one is in the Happening Now deck AND the list: HOST +
    // YOU'RE IN on both. The hosted one is only in the list (3h out).
    expect(find.text('YOU\'RE IN'), findsNWidgets(2));
    expect(find.text('HOST'), findsNWidgets(2));
    expect(find.text('YOU\'RE HOSTING'), findsOneWidget);
  });

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

  group('a cancelled meetup awaiting the participant\'s review', () {
    Meetup cancelledTomorrow() => _meetup(
      id: 'cx',
      hostFullName: 'Grace Hopper',
      windowStart: DateTime.now().add(const Duration(days: 1)),
      windowEnd: DateTime.now().add(const Duration(days: 1, hours: 2)),
      status: MeetupStatus.cancelled,
      cancellationReason: 'Came down with something, so sorry.',
    );

    testWidgets('gets its own CANCELLED section above Happening Now, with '
        'the host\'s reason and a review prompt; it is not in the live deck '
        'and its row in Active Meetups is marked', (tester) async {
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final live = _meetup(
        id: 'live',
        hostFullName: 'Live Host',
        windowStart: DateTime.now().subtract(const Duration(minutes: 5)),
        windowEnd: DateTime.now().add(const Duration(hours: 1)),
      );
      final service = ScriptedMeetupService(
        activeMeetups: [live, cancelledTomorrow()],
      );
      await tester.pumpWidget(_appWith(service));
      await tester.pumpAndSettle();

      expect(find.text('CANCELLED'), findsWidgets);
      expect(
        find.text('\u201CCame down with something, so sorry.\u201D'),
        findsOneWidget,
      );
      expect(
        find.text('Share your thoughts on this cancellation'),
        findsOneWidget,
      );
      // The section order: CANCELLED before HAPPENING NOW.
      final cancelledY = tester.getTopLeft(find.text('CANCELLED').first).dy;
      final nowY = tester.getTopLeft(find.text('HAPPENING NOW')).dy;
      expect(cancelledY, lessThan(nowY));
      // The live deck holds only the live meetup.
      expect(find.byType(PageView), findsNothing);
      // And it is NOT repeated as a row in Active Meetups: that list is
      // only for meetups still going ahead.
      expect(find.text('CANCELLED \u00B7 COFFEE'), findsNothing);
      expect(find.text('ACTIVE MEETUPS'), findsOneWidget);
    });

    testWidgets('tapping the prompt opens the review flow framed as a '
        'cancellation', (tester) async {
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final service = ScriptedMeetupService(
        activeMeetups: [cancelledTomorrow()],
      );
      await tester.pumpWidget(_appWith(service));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Share your thoughts on this cancellation'));
      await tester.pumpAndSettle();

      final page = tester.widget<MeetupReviewPage>(
        find.byType(MeetupReviewPage),
      );
      expect(page.cancellationReason, 'Came down with something, so sorry.');
      expect(
        find.text('THIS MEETUP WAS CANCELLED BY THE HOST'),
        findsOneWidget,
      );
    });
  });
}
