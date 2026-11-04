import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/widgets/app_icons.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/public_profile.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/features/profile/public_profile_page.dart';

import 'support/app_icon_finder.dart';

import 'support/fake_auth_service.dart';

/// # WHAT THIS FILE GUARDS
///
/// The public profile shows another member's record and verification
/// badges and NOTHING that identifies them beyond name and photo. The
/// backend enforces that structurally (its response type has no private
/// field), and this page is built on the matching [PublicProfile] — so the
/// tests here pin the rendering contract: which badge lights for which
/// flag, that unverified rows are shown as unverified rather than hidden,
/// and that the page loads its data exactly once.
void main() {
  Widget pageWith(ImmediateAuthService auth, {String? initialName}) =>
      ProviderScope(
        overrides: [authServiceProvider.overrideWithValue(auth)],
        child: MaterialApp(
          home: PublicProfilePage(userId: 'user-9', initialName: initialName),
        ),
      );

  testWidgets('renders name, level, record, and lights only the badges the '
      'member actually holds', (tester) async {
    final auth = ImmediateAuthService()
      ..publicProfileFor = (id) => PublicProfile(
        id: id,
        fullName: 'Grace Hopper',
        trustLevel: 3,
        ratingAverage: 4.5,
        ratingCount: 12,
        meetupsCompleted: 9,
        linkedInConnected: true,
        workEmailVerified: true,
        phoneVerified: false,
      );

    await tester.pumpWidget(pageWith(auth));
    await tester.pumpAndSettle();

    expect(find.text('Grace Hopper'), findsOneWidget);
    expect(find.text('L3 Trust'), findsOneWidget);
    expect(find.text('9'), findsOneWidget);
    // The rating is the stat tile's own number now, not a star row — the
    // tile is the same one the member's own profile uses.
    expect(find.text('4.5'), findsOneWidget);

    // All three rows are always listed — an unverified one is shown as
    // not yet verified, not hidden, so the absence itself is information.
    expect(find.text('Professional'), findsOneWidget);
    expect(find.text('Official'), findsOneWidget);
    expect(find.text('Phone verified'), findsOneWidget);
    expect(find.text('Verified'), findsNWidgets(3));
    // One section label plus the two rows that hold it.
    expect(findAppIcon(AppIcons.check), findsNWidgets(2));
    // The unverified row says so outright rather than greying out.
    expect(findAppIcon(AppIcons.minus), findsOneWidget);
    expect(find.text('Not yet'), findsOneWidget);
  });

  testWidgets('a member with no ratings yet says so instead of showing an '
      'empty star row', (tester) async {
    final auth = ImmediateAuthService()
      ..publicProfileFor = (id) =>
          PublicProfile(id: id, fullName: 'New Member', trustLevel: 0);

    await tester.pumpWidget(pageWith(auth));
    await tester.pumpAndSettle();

    expect(find.text('No ratings yet'), findsOneWidget);
  });

  testWidgets('the caller\'s name shows immediately while the profile loads', (
    tester,
  ) async {
    final auth = ImmediateAuthService()
      ..publicProfileFor = (id) =>
          PublicProfile(id: id, fullName: 'Grace Hopper', trustLevel: 2);

    await tester.pumpWidget(pageWith(auth, initialName: 'Grace Hopper'));
    // One frame only — the future has not resolved yet.
    await tester.pump();

    expect(find.text('Grace Hopper'), findsOneWidget);
  });

  testWidgets('fetches the profile exactly once, however often it rebuilds', (
    tester,
  ) async {
    var calls = 0;
    final auth = ImmediateAuthService()
      ..publicProfileFor = (id) {
        calls++;
        return PublicProfile(id: id, fullName: 'Grace Hopper', trustLevel: 2);
      };

    await tester.pumpWidget(pageWith(auth));
    await tester.pumpAndSettle();
    // Force rebuilds the way a theme change or keyboard would.
    tester.view.physicalSize = const Size(900, 1800);
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1000, 2000);
    await tester.pumpAndSettle();

    expect(calls, 1);
  });

  testWidgets('a host shows finished meetups and anonymous reviews', (
    tester,
  ) async {
    final auth = ImmediateAuthService()
      ..publicProfileFor = (id) => PublicProfile(
        id: id,
        fullName: 'Grace Hopper',
        trustLevel: 3,
        meetupsCompleted: 2,
        recentMeetups: [
          MemberMeetup(
            intent: IntentType.coffee,
            day: DateTime(2026, 9, 1, 12),
            locationLabel: 'Colombo Fort',
            participantCount: 3,
            overallAverage: 4.5,
            reviewCount: 2,
          ),
          MemberMeetup(
            intent: IntentType.lunch,
            day: DateTime(2026, 8, 20, 12),
            locationLabel: 'Kollupitiya',
            participantCount: 2,
            overallAverage: 0,
            reviewCount: 0,
          ),
        ],
        reviews: const [
          MemberReview(score: 4, text: 'Great chat.', month: '2026-09'),
        ],
      );

    await tester.pumpWidget(pageWith(auth));
    await tester.pumpAndSettle();

    expect(find.text('Recent meetups'), findsOneWidget);
    expect(find.text('Coffee'), findsOneWidget);
    expect(find.text('Sep 1, 2026'), findsOneWidget);
    expect(find.text('3 people'), findsOneWidget);
    expect(find.text('Not rated yet'), findsOneWidget);
    // The date stands alone: no hour of the day.
    expect(find.textContaining('PM'), findsNothing);
    expect(find.text('Hosted'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('\u201CGreat chat.\u201D'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('A participant'), findsOneWidget);
    expect(find.text('September 2026'), findsOneWidget);
  });

  testWidgets('a host with no reviews says so', (tester) async {
    final auth = ImmediateAuthService()
      ..publicProfileFor = (id) => PublicProfile(
        id: id,
        fullName: 'Grace Hopper',
        trustLevel: 3,
        meetupsCompleted: 1,
        recentMeetups: [
          MemberMeetup(
            intent: IntentType.coffee,
            day: DateTime(2026, 9, 1, 12),
            locationLabel: 'Colombo Fort',
            participantCount: 3,
            overallAverage: 0,
            reviewCount: 0,
          ),
        ],
      );
    await tester.pumpWidget(pageWith(auth));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('No reviews yet'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('No reviews yet'), findsOneWidget);
  });

  testWidgets('a member with no meetups says so', (tester) async {
    final auth = ImmediateAuthService()
      ..publicProfileFor = (id) =>
          PublicProfile(id: id, fullName: 'Ada', trustLevel: 2);
    await tester.pumpWidget(pageWith(auth));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('No meetups yet'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Reviews'), findsNothing);
  });

  testWidgets('a member who only joined lists no meetups and no reviews', (
    tester,
  ) async {
    final auth = ImmediateAuthService()
      ..publicProfileFor = (id) => PublicProfile(
        id: id,
        fullName: 'Ada',
        trustLevel: 2,
        meetupsCompleted: 4,
        ratingAverage: 4.5,
        ratingCount: 3,
      );
    await tester.pumpWidget(pageWith(auth));
    await tester.pumpAndSettle();
    expect(find.text('Recent meetups'), findsNothing);
    expect(find.text('No meetups yet'), findsNothing);
    expect(find.text('Reviews'), findsNothing);
  });

  test('a review from the server keeps score, text and month only', () {
    final profile = PublicProfile.fromJson({
      'user_id': 'u',
      'recent_meetups': [
        {
          'id': '',
          'intent': 'coffee',
          'status': 'completed',
          'window_start_unix_seconds': 1788242400,
          'window_end_unix_seconds': 1788242400,
          'hosted': true,
        },
      ],
      'reviews': [
        {'score': 4, 'text': 'Nice.', 'month': '2026-09'},
      ],
    });
    expect(profile.recentMeetups.single.intent, IntentType.coffee);
    expect(profile.reviews.single.text, 'Nice.');
    expect(profile.reviews.single.month, '2026-09');
  });

  testWidgets('a refused profile is shown as a locked state with the '
      'server\'s sentence, not as an error', (tester) async {
    final auth = ImmediateAuthService()
      ..publicProfileFor = (_) => throw const ForbiddenActionException(
        'You can see a member\'s profile once you share a meetup with them.',
      );

    await tester.pumpWidget(pageWith(auth, initialName: 'Someone'));
    await tester.pumpAndSettle();

    expect(findAppIcon(AppIcons.lock), findsOneWidget);
    expect(
      find.text(
        'You can see a member\'s profile once you share a meetup with them.',
      ),
      findsOneWidget,
    );
    expect(find.text('Recent meetups'), findsNothing);
  });
}
