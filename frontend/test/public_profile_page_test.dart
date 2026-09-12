import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/public_profile.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/widgets/star_rating.dart';
import 'package:professional_connections_platform/features/profile/public_profile_page.dart';

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
    expect(find.byType(StarRating), findsOneWidget);

    // All three rows are always listed — an unverified one is shown as
    // not verified, not hidden, so the absence itself is information.
    expect(find.text('Professional'), findsOneWidget);
    expect(find.text('Official'), findsOneWidget);
    expect(find.text('Phone verified'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsNWidgets(2));
    // The unverified row says so outright rather than greying out.
    expect(find.byIcon(Icons.cancel_outlined), findsOneWidget);
    expect(find.text('Not verified'), findsOneWidget);
  });

  testWidgets('a member with no ratings yet says so instead of showing an '
      'empty star row', (tester) async {
    final auth = ImmediateAuthService()
      ..publicProfileFor = (id) =>
          PublicProfile(id: id, fullName: 'New Member', trustLevel: 0);

    await tester.pumpWidget(pageWith(auth));
    await tester.pumpAndSettle();

    expect(find.text('No ratings yet'), findsOneWidget);
    expect(find.byType(StarRating), findsNothing);
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

  testWidgets('recent meetups render role, turnout, rating, and comments — '
      'anonymous where the server withheld the author', (tester) async {
    final auth = ImmediateAuthService()
      ..publicProfileFor = (id) => PublicProfile(
        id: id,
        fullName: 'Grace Hopper',
        trustLevel: 3,
        recentMeetups: [
          MemberMeetup(
            id: 'm-1',
            intent: IntentType.coffee,
            status: 'completed',
            windowStart: DateTime(2026, 9, 1, 15),
            windowEnd: DateTime(2026, 9, 1, 16),
            locationLabel: 'Colombo Fort Cafe',
            hosted: true,
            participantCount: 3,
            overallAverage: 4.5,
            reviewCount: 2,
            viewerWasIn: false,
            comments: [
              MemberMeetupComment(
                authorName: '',
                note: 'Great chat.',
                writtenAt: DateTime(2026, 9, 2),
              ),
            ],
          ),
          MemberMeetup(
            id: 'm-2',
            intent: IntentType.lunch,
            status: 'completed',
            windowStart: DateTime(2026, 8, 20, 12),
            windowEnd: DateTime(2026, 8, 20, 13),
            locationLabel: 'Ministry of Crab',
            hosted: false,
            participantCount: 2,
            overallAverage: 0,
            reviewCount: 0,
            viewerWasIn: true,
            comments: [
              MemberMeetupComment(
                authorName: 'Ada Lovelace',
                note: 'Lovely spot.',
                writtenAt: DateTime(2026, 8, 21),
              ),
            ],
          ),
        ],
      );

    await tester.pumpWidget(pageWith(auth));
    await tester.pumpAndSettle();

    expect(find.text('RECENT MEETUPS'), findsOneWidget);
    expect(find.text('HOSTED'), findsOneWidget);
    expect(find.text('JOINED'), findsOneWidget);
    expect(find.text('3 people'), findsOneWidget);
    expect(find.text('Not rated yet'), findsOneWidget);
    // Comments render as quotations with an attributed line under each.
    expect(find.text('\u201CGreat chat.\u201D'), findsOneWidget);
    expect(find.text('\u2014 A participant'), findsOneWidget);
    expect(find.text('\u2014 Ada Lovelace'), findsOneWidget);
  });

  testWidgets('a refused profile is shown as a locked state with the '
      'server\'s sentence, not as an error', (tester) async {
    final auth = ImmediateAuthService()
      ..publicProfileFor = (_) => throw const ForbiddenActionException(
        'You can see a member\'s profile once you share a meetup with them.',
      );

    await tester.pumpWidget(pageWith(auth, initialName: 'Someone'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    expect(
      find.text(
        'You can see a member\'s profile once you share a meetup with them.',
      ),
      findsOneWidget,
    );
    expect(find.text('RECENT MEETUPS'), findsNothing);
  });
}
