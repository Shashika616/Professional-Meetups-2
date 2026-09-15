import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/widgets/meetup_role_chips.dart';

Meetup _meetup({
  bool isHostedByMe = false,
  MeetupRequestStatus? myRequestStatus,
  String? hostFullName = 'Ada Lovelace',
}) => Meetup(
  id: 'm1',
  hostUserId: 'host',
  hostTrustLevel: 3,
  hostFullName: hostFullName,
  intent: IntentType.coffee,
  windowStart: DateTime(2026, 9, 15, 17),
  windowEnd: DateTime(2026, 9, 15, 18),
  capacity: 2,
  acceptedCount: 0,
  status: MeetupStatus.open,
  createdAt: DateTime(2026, 9, 14),
  isHostedByMe: isHostedByMe,
  myRequestStatus: myRequestStatus,
);

Future<void> _pump(WidgetTester tester, Widget chips) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: chips)));

/// The chips say the same thing in two tenses: present while a meetup is
/// on, past once it is over or called off (the review and cancelled decks
/// on Home). A present-tense chip on a finished meetup reads as if it were
/// still happening, which is the bug this pins.
void main() {
  group('present tense (default)', () {
    testWidgets('host', (tester) async {
      await _pump(tester, MeetupRoleChips(meetup: _meetup(isHostedByMe: true)));
      expect(find.text("YOU'RE HOSTING"), findsOneWidget);
    });

    testWidgets('accepted viewer, with the host named', (tester) async {
      await _pump(
        tester,
        MeetupRoleChips(
          meetup: _meetup(myRequestStatus: MeetupRequestStatus.accepted),
        ),
      );
      expect(find.text('HOST · ADA LOVELACE'), findsOneWidget);
      expect(find.text("YOU'RE IN"), findsOneWidget);
    });

    testWidgets('pending viewer', (tester) async {
      await _pump(
        tester,
        MeetupRoleChips(
          meetup: _meetup(myRequestStatus: MeetupRequestStatus.pending),
          showHostName: false,
        ),
      );
      expect(find.text('HOST'), findsOneWidget);
      expect(find.text('REQUEST PENDING'), findsOneWidget);
    });
  });

  group('past tense (concluded)', () {
    testWidgets('host', (tester) async {
      await _pump(
        tester,
        MeetupRoleChips(meetup: _meetup(isHostedByMe: true), concluded: true),
      );
      expect(find.text('YOU HOSTED'), findsOneWidget);
      expect(find.text("YOU'RE HOSTING"), findsNothing);
    });

    testWidgets('accepted viewer, with and without the host named', (
      tester,
    ) async {
      await _pump(
        tester,
        MeetupRoleChips(
          meetup: _meetup(myRequestStatus: MeetupRequestStatus.accepted),
          concluded: true,
        ),
      );
      expect(find.text('HOSTED BY ADA LOVELACE'), findsOneWidget);
      expect(find.text('YOU JOINED'), findsOneWidget);

      await _pump(
        tester,
        MeetupRoleChips(
          meetup: _meetup(myRequestStatus: MeetupRequestStatus.accepted),
          concluded: true,
          showHostName: false,
        ),
      );
      expect(find.text('HOSTED'), findsOneWidget);
    });

    testWidgets('a request nobody answered', (tester) async {
      await _pump(
        tester,
        MeetupRoleChips(
          meetup: _meetup(myRequestStatus: MeetupRequestStatus.pending),
          concluded: true,
        ),
      );
      expect(find.text('NOT ANSWERED'), findsOneWidget);
      expect(find.text('REQUEST PENDING'), findsNothing);
    });

    testWidgets('rejected and withdrawn already read as past', (tester) async {
      await _pump(
        tester,
        MeetupRoleChips(
          meetup: _meetup(myRequestStatus: MeetupRequestStatus.rejected),
          concluded: true,
        ),
      );
      expect(find.text('NOT SELECTED'), findsOneWidget);
    });
  });
}
