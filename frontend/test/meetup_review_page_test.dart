import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/features/meetups/review/experience_scale.dart';
import 'package:professional_connections_platform/features/meetups/review/meetup_review_page.dart';

import 'support/scripted_meetup_service.dart';

const _host = RatableParticipant(
  userId: 'host-1',
  fullName: 'Grace Hopper',
  trustLevel: 3,
);
const _guest = RatableParticipant(
  userId: 'guest-1',
  fullName: 'Ada Lovelace',
  trustLevel: 2,
);

Widget _appWith(ScriptedMeetupService service) => ProviderScope(
  overrides: [meetupServiceProvider.overrideWithValue(service)],
  child: const MaterialApp(
    home: MeetupReviewPage(meetupId: 'meetup-1', hostUserId: 'host-1'),
  ),
);

Future<void> _pickOverall(WidgetTester tester, ExperienceLevel level) async {
  // The slider is five equal stops across its own width.
  // The picture above is full-width now, so the slider can sit below a
  // bare test viewport — scroll it in before reading its rect.
  await tester.ensureVisible(find.byType(ExperienceSlider));
  await tester.pumpAndSettle();
  final slider = tester.getRect(find.byType(ExperienceSlider));
  final step = slider.width / ExperienceLevel.values.length;
  await tester.tapAt(
    Offset(slider.left + step * (level.index + 0.5), slider.center.dy),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens on the overall question, and NEXT is dead until it is '
      'answered', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final service = ScriptedMeetupService(ratableParticipants: [_host]);
    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    expect(find.text('How was your experience?'), findsOneWidget);
    expect(find.text('Pick a rating'), findsOneWidget);

    // Tapping a disabled NEXT must not advance — otherwise someone lands on
    // a Confirm that can never succeed.
    await tester.tap(find.text('NEXT'));
    await tester.pumpAndSettle();
    expect(find.text('How was your experience?'), findsOneWidget);
    expect(find.text('Who did you meet?'), findsNothing);
  });

  testWidgets('the face and its word follow the slider', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final service = ScriptedMeetupService(ratableParticipants: [_host]);
    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    // Every level's word is now also printed under its stop on the slider,
    // so the headline is found by its per-level key, not by text.
    Finder headline(ExperienceLevel l) =>
        find.byKey(ValueKey<ExperienceLevel?>(l));

    await _pickOverall(tester, ExperienceLevel.veryBad);
    expect(headline(ExperienceLevel.veryBad), findsOneWidget);

    await _pickOverall(tester, ExperienceLevel.excellent);
    expect(headline(ExperienceLevel.excellent), findsOneWidget);
    expect(headline(ExperienceLevel.veryBad), findsNothing);
  });

  testWidgets('CONFIRM stays disabled until every participant is rated — the '
      'server refuses a partial review, so the button must not offer one', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final service = ScriptedMeetupService(ratableParticipants: [_host, _guest]);
    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    await _pickOverall(tester, ExperienceLevel.good);
    await tester.tap(find.text('NEXT'));
    await tester.pumpAndSettle();

    expect(find.text('Who did you meet?'), findsOneWidget);
    expect(find.text('Grace Hopper'), findsOneWidget);
    expect(find.text('Ada Lovelace'), findsOneWidget);
    // The host is badged so a participant knows who they are rating.
    expect(find.text('HOST'), findsOneWidget);

    await tester.tap(find.text('CONFIRM'));
    await tester.pumpAndSettle();
    expect(
      service.submitReviewCallCount,
      0,
      reason: 'nobody has been rated yet',
    );

    // Rate only the first of the two. The cards render in order, five stars
    // each, so index 4 is the first person's fifth star.
    await tester.tap(find.byIcon(Icons.star_outline_rounded).at(4));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CONFIRM'));
    await tester.pumpAndSettle();
    expect(
      service.submitReviewCallCount,
      0,
      reason: 'one of two participants is still unrated',
    );
  });

  testWidgets('a complete review submits once, carrying every score and the '
      'chosen traits', (tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final service = ScriptedMeetupService(ratableParticipants: [_host]);
    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Great conversation.');
    await _pickOverall(tester, ExperienceLevel.excellent);
    await tester.tap(find.text('NEXT'));
    await tester.pumpAndSettle();

    // Fourth star.
    await tester.tap(find.byIcon(Icons.star_outline_rounded).at(3));
    await tester.pumpAndSettle();

    // The trait picker only appears once a score is given.
    expect(find.text('Cheerful'), findsOneWidget);
    await tester.tap(find.text('Cheerful'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('CONFIRM'));
    await tester.pumpAndSettle();

    expect(service.submitReviewCallCount, 1);
    expect(service.lastReviewOverallScore, 5);
    expect(service.lastReviewNotes, 'Great conversation.');
    expect(service.lastReviewParticipants, hasLength(1));
    expect(service.lastReviewParticipants.single.userId, 'host-1');
    expect(service.lastReviewParticipants.single.score, 4);
    expect(service.lastReviewParticipants.single.traits, ['cheerful']);
  });

  testWidgets('the trait picker is hidden until a score is given', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final service = ScriptedMeetupService(ratableParticipants: [_host]);
    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    await _pickOverall(tester, ExperienceLevel.good);
    await tester.tap(find.text('NEXT'));
    await tester.pumpAndSettle();

    // Twelve chips per person opening by default would bury the thing
    // actually being asked for.
    expect(find.text('Cheerful'), findsNothing);
  });

  testWidgets('traits sit under Positive and Negative tabs sharing one cap of '
      'four, and the submission carries picks from both', (tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final service = ScriptedMeetupService(ratableParticipants: [_host]);
    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    await _pickOverall(tester, ExperienceLevel.good);
    await tester.tap(find.text('NEXT'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.star_outline_rounded).at(1));
    await tester.pumpAndSettle();

    expect(find.text('What were they like? (up to 4)'), findsOneWidget);
    // Positive tab first; nothing critical is on screen until asked for.
    expect(find.text('Cheerful'), findsOneWidget);
    expect(find.text('Arrived late'), findsNothing);

    for (final label in ['Cheerful', 'Great listener', 'Insightful']) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byKey(const Key('traitTabNegative')));
    await tester.pumpAndSettle();
    expect(find.text('Arrived late'), findsOneWidget);
    expect(find.text('Cheerful'), findsNothing);
    // The other tab's count travels with it.
    expect(find.text('3'), findsOneWidget);

    await tester.tap(find.text('Arrived late'));
    await tester.pumpAndSettle();
    // Fourth pick reached the cap: a fifth is refused across tabs.
    await tester.tap(find.text('Distracted'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('CONFIRM'));
    await tester.pumpAndSettle();

    expect(service.submitReviewCallCount, 1);
    expect(
      service.lastReviewParticipants.single.traits,
      unorderedEquals([
        'cheerful',
        'great_listener',
        'insightful',
        'arrived_late',
      ]),
    );
  });

  testWidgets('a vocabulary with no negative half (an older server) renders '
      'with no tabs at all', (tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final service = ScriptedMeetupService(ratableParticipants: [_host])
      ..availableTraits = const [
        RatingTrait(key: 'cheerful', label: 'Cheerful', emoji: '☀️'),
      ];
    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    await _pickOverall(tester, ExperienceLevel.good);
    await tester.tap(find.text('NEXT'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.star_outline_rounded).at(1));
    await tester.pumpAndSettle();

    expect(find.text('Cheerful'), findsOneWidget);
    expect(find.byKey(const Key('traitTabPositive')), findsNothing);
    expect(find.byKey(const Key('traitTabNegative')), findsNothing);
  });

  testWidgets('with no trait vocabulary, the trait header is not rendered '
      'over blank space — an older server sends none', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final service = ScriptedMeetupService(ratableParticipants: [_host])
      ..availableTraits = const [];
    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    await _pickOverall(tester, ExperienceLevel.good);
    await tester.tap(find.text('NEXT'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.star_outline_rounded).at(4));
    await tester.pumpAndSettle();

    expect(find.textContaining('What were they like?'), findsNothing);
    // And the rating itself still works, so a missing vocabulary degrades
    // rather than blocking.
    await tester.tap(find.text('CONFIRM'));
    await tester.pumpAndSettle();
    expect(service.submitReviewCallCount, 1);
    expect(service.lastReviewParticipants.single.traits, isEmpty);
  });

  testWidgets('with people to rate, step one offers NEXT and never SUBMIT — '
      'submitting there would stamp the meetup reviewed with nobody rated, '
      'and ratings are immutable', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final service = ScriptedMeetupService(ratableParticipants: [_host, _guest]);
    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    await _pickOverall(tester, ExperienceLevel.good);

    expect(find.text('NEXT'), findsOneWidget);
    expect(find.text('SUBMIT'), findsNothing);

    await tester.tap(find.text('NEXT'));
    await tester.pumpAndSettle();

    expect(find.text('Who did you meet?'), findsOneWidget);
    expect(
      service.submitReviewCallCount,
      0,
      reason: 'nothing may be written until Confirm on the people step',
    );
  });

  testWidgets('a meetup with nobody else to rate skips the second step '
      'entirely', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final service = ScriptedMeetupService(ratableParticipants: const []);
    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    await _pickOverall(tester, ExperienceLevel.okay);
    // There is no second step to offer, so the button says what it does.
    expect(find.text('SUBMIT'), findsOneWidget);
    expect(find.text('NEXT'), findsNothing);

    await tester.ensureVisible(find.text('SUBMIT'));
    await tester.tap(find.text('SUBMIT'));
    await tester.pumpAndSettle();

    expect(service.submitReviewCallCount, 1);
    expect(service.lastReviewParticipants, isEmpty);
  });

  testWidgets('a failed submission keeps the review on screen so it can be '
      'retried, and says why', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final service = ScriptedMeetupService(ratableParticipants: const [])
      ..submitReviewError = const MeetupConflictException(
        'This meetup is already reviewed.',
      );
    await tester.pumpWidget(_appWith(service));
    await tester.pumpAndSettle();

    await _pickOverall(tester, ExperienceLevel.good);
    await tester.ensureVisible(find.text('SUBMIT'));
    await tester.tap(find.text('SUBMIT'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('This meetup is already reviewed.'), findsOneWidget);
    expect(find.text('How was your experience?'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a cancellation review says so first, and asks to rate the '
      'host rather than "who did you meet"', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final service = ScriptedMeetupService(ratableParticipants: [_host]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [meetupServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(
          home: MeetupReviewPage(
            meetupId: 'meetup-1',
            hostUserId: 'host-1',
            cancellationReason: 'Family emergency.',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('THIS MEETUP WAS CANCELLED BY THE HOST'), findsOneWidget);
    expect(find.text('\u201CFamily emergency.\u201D'), findsOneWidget);
    expect(find.text('How was this for you?'), findsOneWidget);

    await _pickOverall(tester, ExperienceLevel.bad);
    await tester.ensureVisible(find.text('NEXT'));
    await tester.tap(find.text('NEXT'));
    await tester.pumpAndSettle();

    expect(find.text('Rate the host'), findsOneWidget);
    expect(find.text('Who did you meet?'), findsNothing);
  });
}
