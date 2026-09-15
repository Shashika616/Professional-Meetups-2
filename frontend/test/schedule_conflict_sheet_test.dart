import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/features/meetups/meetup_detail_page.dart';
import 'package:professional_connections_platform/features/meetups/widgets/schedule_conflict_sheet.dart';

import 'support/scripted_meetup_service.dart';

Meetup _conflict({
  bool isHostedByMe = false,
  MeetupRequestStatus? myRequestStatus,
}) => Meetup(
  id: 'busy-1',
  hostUserId: 'host',
  hostTrustLevel: 3,
  hostFullName: 'Ada Lovelace',
  intent: IntentType.coffee,
  windowStart: DateTime(2026, 9, 15, 17),
  windowEnd: DateTime(2026, 9, 15, 18, 30),
  locationLabel: 'Barefoot Cafe',
  capacity: 2,
  acceptedCount: 0,
  status: MeetupStatus.open,
  createdAt: DateTime(2026, 9, 14),
  isHostedByMe: isHostedByMe,
  myRequestStatus: myRequestStatus,
);

/// Pumps a page with one button that opens the sheet for [conflict].
Future<void> _pumpAndOpen(WidgetTester tester, Meetup conflict) async {
  final service = ScriptedMeetupService(
    meetupDetail: conflict,
    safetyState: const SafetyState(meetupId: 'busy-1'),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [meetupServiceProvider.overrideWithValue(service)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showScheduleConflictSheet(
                context,
                error: MeetupScheduleConflictException(
                  'busy',
                  conflict: conflict,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('names the hosted meetup in the way, when it ends, and the '
      'way out', (tester) async {
    await _pumpAndOpen(tester, _conflict(isHostedByMe: true));

    expect(find.text('ONE MEETUP AT A TIME'), findsOneWidget);
    expect(
      find.text("You're already hosting a meetup at that time"),
      findsOneWidget,
    );
    expect(find.text('YOU HOSTED'), findsNothing);
    expect(find.text("YOU'RE HOSTING"), findsOneWidget);
    expect(find.text('Barefoot Cafe'), findsOneWidget);
    expect(find.textContaining('5:00–6:30 PM'), findsOneWidget);
    expect(
      find.text(
        'Wait until it ends at 6:30 PM, or cancel that meetup to free the '
        'time.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a pending request is told to cancel the request', (
    tester,
  ) async {
    await _pumpAndOpen(
      tester,
      _conflict(myRequestStatus: MeetupRequestStatus.pending),
    );
    expect(
      find.text("You've already asked to join a meetup at that time"),
      findsOneWidget,
    );
    expect(find.textContaining('cancel that request'), findsOneWidget);
  });

  testWidgets('an accepted request is told to withdraw', (tester) async {
    await _pumpAndOpen(
      tester,
      _conflict(myRequestStatus: MeetupRequestStatus.accepted),
    );
    expect(
      find.text("You're already in a meetup at that time"),
      findsOneWidget,
    );
    expect(find.textContaining('withdraw from it'), findsOneWidget);
  });

  testWidgets('OPEN THAT MEETUP closes the sheet and opens the detail page '
      'for the meetup in the way', (tester) async {
    await _pumpAndOpen(tester, _conflict(isHostedByMe: true));
    await tester.tap(find.text('OPEN THAT MEETUP'));
    await tester.pumpAndSettle();

    expect(find.text('ONE MEETUP AT A TIME'), findsNothing);
    final page = tester.widget<MeetupDetailPage>(find.byType(MeetupDetailPage));
    expect(page.meetupId, 'busy-1');
  });

  testWidgets("I'LL WAIT just closes the sheet", (tester) async {
    await _pumpAndOpen(tester, _conflict(isHostedByMe: true));
    await tester.tap(find.text("I'LL WAIT"));
    await tester.pumpAndSettle();

    expect(find.text('ONE MEETUP AT A TIME'), findsNothing);
    expect(find.byType(MeetupDetailPage), findsNothing);
  });
}
