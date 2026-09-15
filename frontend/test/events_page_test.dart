import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/models/public_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/meetup_status_badge.dart';
import 'package:professional_connections_platform/core/widgets/star_rating.dart';
import 'package:professional_connections_platform/core/widgets/trust_level_badge.dart';
import 'package:professional_connections_platform/features/meetups/events_page.dart';

import 'support/fake_auth_service.dart';
import 'support/scripted_meetup_service.dart';
import 'package:professional_connections_platform/features/meetups/meetup_detail_page.dart';
import 'package:professional_connections_platform/features/profile/public_profile_page.dart';

Meetup _hostedMeetup({String id = 'meetup-1'}) => Meetup(
  id: id,
  hostUserId: 'me',
  hostFullName: 'Me',
  hostTrustLevel: 3,
  intent: IntentType.coffee,
  windowStart: DateTime.now().add(const Duration(hours: 1)),
  windowEnd: DateTime.now().add(const Duration(hours: 3)),
  locationLat: 6.9271,
  locationLng: 79.8612,
  locationLabel: 'Colombo Fort Cafe',
  capacity: 4,
  acceptedCount: 0,
  status: MeetupStatus.open,
  createdAt: DateTime.now(),
  isHostedByMe: true,
);

Meetup _hostedMeetupFinished({String id = 'meetup-1'}) => Meetup(
  id: id,
  hostUserId: 'me',
  hostFullName: 'Me',
  hostTrustLevel: 3,
  intent: IntentType.coffee,
  windowStart: DateTime.now().subtract(const Duration(hours: 3)),
  windowEnd: DateTime.now().subtract(const Duration(hours: 1)),
  locationLat: 6.9271,
  locationLng: 79.8612,
  locationLabel: 'Colombo Fort Cafe',
  capacity: 4,
  acceptedCount: 1,
  status: MeetupStatus.completed,
  createdAt: DateTime.now().subtract(const Duration(days: 1)),
  isHostedByMe: true,
);

/// A finished meetup the viewer REQUESTED (not hosted), keeping its
/// terminal status — copyWithRequestStatus resets status to open, which is
/// right for the open-tab tests it serves and wrong for History, where the
/// open/history split is decided by status.
Meetup _requestedFinished({
  String id = 'meetup-1',
  MeetupStatus status = MeetupStatus.completed,
  MeetupRequestStatus myRequestStatus = MeetupRequestStatus.accepted,
  String? cancellationReason,
}) => Meetup(
  id: id,
  hostUserId: 'host-9',
  hostFullName: 'Grace Hopper',
  hostTrustLevel: 3,
  intent: IntentType.coffee,
  windowStart: DateTime.now().subtract(const Duration(hours: 3)),
  windowEnd: DateTime.now().subtract(const Duration(hours: 1)),
  locationLat: 6.9271,
  locationLng: 79.8612,
  locationLabel: 'Colombo Fort Cafe',
  capacity: 4,
  acceptedCount: 1,
  status: status,
  cancellationReason: cancellationReason,
  createdAt: DateTime.now().subtract(const Duration(days: 1)),
  isHostedByMe: false,
  myRequestStatus: myRequestStatus,
);

Meetup _hostedMeetupStarted({String id = 'meetup-1'}) => Meetup(
  id: id,
  hostUserId: 'me',
  hostFullName: 'Me',
  hostTrustLevel: 3,
  intent: IntentType.coffee,
  windowStart: DateTime.now().subtract(const Duration(minutes: 15)),
  windowEnd: DateTime.now().add(const Duration(hours: 1)),
  locationLat: 6.9271,
  locationLng: 79.8612,
  locationLabel: 'Colombo Fort Cafe',
  capacity: 4,
  acceptedCount: 0,
  status: MeetupStatus.open,
  createdAt: DateTime.now(),
  isHostedByMe: true,
);

MeetupRequestModel _pendingRequest({
  String id = 'request-1',
  String requesterFullName = 'Grace Hopper',
  int requesterTrustLevel = 2,
}) => MeetupRequestModel(
  id: id,
  meetupId: 'meetup-1',
  requesterId: 'requester-1',
  requesterFullName: requesterFullName,
  requesterTrustLevel: requesterTrustLevel,
  status: MeetupRequestStatus.pending,
  createdAt: DateTime.now(),
);

MeetupRequestModel _request({
  required String id,
  required String requesterFullName,
  required MeetupRequestStatus status,
  String? withdrawalNote,
  DateTime? checkedInAt,
  DateTime? declinedAt,
  String? declineReason,
}) => MeetupRequestModel(
  id: id,
  meetupId: 'meetup-1',
  requesterId: id,
  requesterFullName: requesterFullName,
  requesterTrustLevel: 2,
  status: status,
  createdAt: DateTime.now(),
  withdrawalNote: withdrawalNote,
  checkedInAt: checkedInAt,
  declinedAt: declinedAt,
  declineReason: declineReason,
);

/// A meetup on either side of the open/history split, identifiable by its
/// location label alone — the tile shows intent, status, window and label,
/// and the label is the only one of those a test can make unique per row
/// without also changing what the row means.
Meetup _tabFixture({
  required String id,
  required String label,
  required MeetupStatus status,
  required bool hosted,
}) => Meetup(
  id: id,
  hostUserId: hosted ? 'me' : 'host-1',
  hostFullName: hosted ? 'Me' : 'Grace Hopper',
  hostTrustLevel: 3,
  intent: IntentType.coffee,
  windowStart: DateTime(2026, 9, 7, 10),
  windowEnd: DateTime(2026, 9, 7, 12),
  locationLat: 6.9271,
  locationLng: 79.8612,
  locationLabel: label,
  capacity: 4,
  acceptedCount: 0,
  status: status,
  createdAt: DateTime(2026, 9, 1),
  isHostedByMe: hosted,
);

/// One fixture covering all four (top tab x sub-tab) cells at once, so a
/// wrong tab shows the wrong row rather than an empty list that would pass
/// a weaker assertion.
ScriptedMeetupService _fourCellService() => ScriptedMeetupService(
  myMeetups: (
    hosted: [
      _tabFixture(
        id: 'h-open',
        label: 'Hosted Open Cafe',
        status: MeetupStatus.open,
        hosted: true,
      ),
      _tabFixture(
        id: 'h-done',
        label: 'Hosted History Cafe',
        status: MeetupStatus.completed,
        hosted: true,
      ),
    ],
    requested: [
      _tabFixture(
        id: 'r-open',
        label: 'Requested Open Cafe',
        status: MeetupStatus.open,
        hosted: false,
      ),
      _tabFixture(
        id: 'r-done',
        label: 'Requested History Cafe',
        status: MeetupStatus.cancelled,
        hosted: false,
      ),
    ],
  ),
);

Widget _eventsApp(ScriptedMeetupService service, {int? initialTab}) =>
    ProviderScope(
      overrides: [meetupServiceProvider.overrideWithValue(service)],
      child: MaterialApp(
        home: initialTab == null
            ? const EventsPage()
            : EventsPage(initialTab: initialTab),
      ),
    );

void main() {
  // A host reached _RequestManagementPage for EVERY hosted meetup, including
  // finished ones — and that page has no review section, so the host could
  // never see the review they gave. A participant, routed to
  // MeetupDetailPage, always could.
  group('a finished hosted meetup opens the same past-meetup view a '
      'participant gets', () {
    testWidgets('it shows the review the host gave, not request management', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final service =
          ScriptedMeetupService(
              myMeetups: (
                hosted: [_hostedMeetupFinished()],
                requested: const [],
              ),
              meetupRequests: [_pendingRequest()],
              meetupDetail: _hostedMeetupFinished(),
              safetyState: const SafetyState(meetupId: 'meetup-1'),
            )
            ..meetupReview = const MeetupReview(
              completed: true,
              overallScore: 4,
              notes: 'Good turnout.',
              participants: [
                ReviewedParticipant(
                  userId: 'guest-1',
                  fullName: 'Grace Hopper',
                  score: 5,
                  traits: ['cheerful'],
                ),
              ],
            );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Colombo Fort Cafe').first);
      await tester.pumpAndSettle();

      expect(find.byType(MeetupDetailPage), findsOneWidget);
      expect(find.text('YOUR REVIEW'), findsOneWidget);
      expect(find.text('"Good turnout."'), findsOneWidget);
      expect(find.text('HOW YOU RATED THEM'), findsOneWidget);
      // Request management is for running a meetup, not reviewing a
      // finished one.
      expect(find.text('ACCEPT'), findsNothing);
      expect(find.text('REJECT'), findsNothing);
    });

    testWidgets('an unreviewed one offers the host the review flow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final service = ScriptedMeetupService(
        myMeetups: (hosted: [_hostedMeetupFinished()], requested: const []),
        meetupRequests: const [],
        meetupDetail: _hostedMeetupFinished(),
        safetyState: const SafetyState(meetupId: 'meetup-1'),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Colombo Fort Cafe').first);
      await tester.pumpAndSettle();

      expect(find.text('START REVIEW'), findsOneWidget);
    });

    testWidgets('a LIVE hosted meetup still opens request management — the '
        'host still has to accept and reject people', (tester) async {
      final service = ScriptedMeetupService(
        myMeetups: (hosted: [_hostedMeetup()], requested: const []),
        meetupRequests: [_pendingRequest()],
        meetupDetail: _hostedMeetup(),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Colombo Fort Cafe'));
      await tester.pumpAndSettle();

      expect(find.text('ACCEPT'), findsOneWidget);
      expect(find.byType(MeetupDetailPage), findsNothing);
    });
  });

  testWidgets(
    'tapping a hosted meetup opens request management, rendering Accept/Reject',
    (tester) async {
      final service = ScriptedMeetupService(
        myMeetups: (hosted: [_hostedMeetup()], requested: const []),
        meetupRequests: [_pendingRequest()],
        meetupDetail: _hostedMeetup(),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Colombo Fort Cafe'), findsOneWidget);
      await tester.tap(find.text('Colombo Fort Cafe'));
      await tester.pumpAndSettle();

      expect(find.text('Grace Hopper'), findsOneWidget);
      expect(find.text('ACCEPT'), findsOneWidget);
      expect(find.text('REJECT'), findsOneWidget);
    },
  );

  testWidgets(
    'renders on the app background image, both on the list and the pushed '
    'request-management page — this page is reached via Navigator.push, '
    'not one of AppShell\'s own bottom-nav tabs, so it needs its own '
    'AppBackground rather than inheriting AppShell\'s',
    (tester) async {
      final service = ScriptedMeetupService(
        myMeetups: (hosted: [_hostedMeetup()], requested: const []),
        meetupRequests: [_pendingRequest()],
        meetupDetail: _hostedMeetup(),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AppBackground), findsOneWidget);

      await tester.tap(find.text('Colombo Fort Cafe'));
      await tester.pumpAndSettle();

      // The previous route (EventsPage) stays built underneath by
      // default (PageRoute.maintainState), so this is >=1, not exactly
      // one — the point is _RequestManagementPage contributes its own
      // AppBackground rather than rendering with none at all.
      expect(find.byType(AppBackground), findsWidgets);
      expect(find.text('Grace Hopper'), findsOneWidget);
    },
  );

  testWidgets(
    'tapping ACCEPT calls respondToRequest with that request\'s id and accept:true',
    (tester) async {
      final service = ScriptedMeetupService(
        myMeetups: (hosted: [_hostedMeetup()], requested: const []),
        meetupRequests: [_pendingRequest(id: 'request-99')],
        meetupDetail: _hostedMeetup(),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Colombo Fort Cafe'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('ACCEPT'));
      await tester.pumpAndSettle();

      expect(service.lastRespondToRequestId, 'request-99');
      expect(service.lastRespondToRequestAccept, isTrue);
    },
  );

  testWidgets(
    'tapping REJECT calls respondToRequest with that request\'s id and accept:false',
    (tester) async {
      final service = ScriptedMeetupService(
        myMeetups: (hosted: [_hostedMeetup()], requested: const []),
        meetupRequests: [_pendingRequest(id: 'request-7')],
        meetupDetail: _hostedMeetup(),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Colombo Fort Cafe'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('REJECT'));
      await tester.pumpAndSettle();

      expect(service.lastRespondToRequestId, 'request-7');
      expect(service.lastRespondToRequestAccept, isFalse);
    },
  );

  testWidgets('the Hosting tab shows a status badge on each meetup card', (
    tester,
  ) async {
    final service = ScriptedMeetupService(
      myMeetups: (hosted: [_hostedMeetup()], requested: const []),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [meetupServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(home: EventsPage()),
      ),
    );
    await tester.pumpAndSettle();

    // The OPEN/COMPLETED chip is gone. A card's state is the bar down its
    // left edge now: green while the meetup is live, gold once it is over and
    // owed a review. Asserting on the colour rather than on a chip is the
    // point of the change, so the test follows it there.
    final edges = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) => c.constraints?.maxWidth == 4)
        .map((c) => c.color)
        .toList();

    expect(
      edges,
      contains(AppPalette.verified),
      reason: 'a hosted meetup still ahead of its window reads as live',
    );
    expect(find.byType(MeetupStatusBadge), findsNothing);
  });

  testWidgets(
    'the request-management screen reached from the Hosting tab shows '
    'Cancel/Close — the exact gap this addendum fixes: that screen used to '
    'be Accept/Reject only, with no way to control the meetup itself '
    '(ADR-016 addendum, 2026-08-20)',
    (tester) async {
      final service = ScriptedMeetupService(
        myMeetups: (hosted: [_hostedMeetupStarted()], requested: const []),
        meetupDetail: _hostedMeetupStarted(),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();

      // The normal path: calendar icon (EventsPage itself, already
      // reached) → HOSTING (the default-selected tab) → a hosted meetup.
      await tester.tap(find.text('Colombo Fort Cafe'));
      await tester.pumpAndSettle();

      expect(find.text('CANCEL MEETUP'), findsOneWidget);
      expect(find.text('CLOSE MEETUP'), findsOneWidget);
      expect(
        tester
            .widgetList<MeetupStatusBadge>(find.byType(MeetupStatusBadge))
            .map((b) => b.status),
        contains(MeetupStatus.open),
      );
    },
  );

  testWidgets(
    'CANCEL MEETUP on the request-management screen updates the header '
    'badge to CANCELLED after confirming — a real state change, not just a '
    'visually-present dialog',
    (tester) async {
      final service = ScriptedMeetupService(
        myMeetups: (hosted: [_hostedMeetupStarted()], requested: const []),
        meetupDetail: _hostedMeetupStarted(),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Colombo Fort Cafe'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('CANCEL MEETUP'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Something came up');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'CANCEL MEETUP'));
      await tester.pumpAndSettle();

      expect(service.lastCancelMeetupId, 'meetup-1');
      expect(find.text('CANCELLED'), findsOneWidget);
      // Both actions disappear once cancelled — neither applies anymore.
      expect(find.text('CANCEL MEETUP'), findsNothing);
      expect(find.text('CLOSE MEETUP'), findsNothing);

      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets(
    'the REQUESTED tab distinguishes auto-reject from an explicit host rejection',
    (tester) async {
      final autoRejected = _hostedMeetup(
        id: 'meetup-auto',
      ).copyWithRequestStatus(MeetupRequestStatus.rejected, autoRejected: true);
      final explicitlyRejected = _hostedMeetup(id: 'meetup-explicit')
          .copyWithRequestStatus(
            MeetupRequestStatus.rejected,
            autoRejected: false,
          );

      final service = ScriptedMeetupService(
        myMeetups: (
          hosted: const [],
          requested: [autoRejected, explicitlyRejected],
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();

      // RENAMED by the Home/Events restructure: the tab was 'REQUESTED'.
      await tester.tap(find.text('Requested Meetings'));
      await tester.pumpAndSettle();

      expect(find.textContaining('NOT SELECTED'), findsOneWidget);
      expect(find.text('DECLINED BY HOST'), findsOneWidget);
    },
  );

  group('Request-management screen — three explicit tabs partition a mixed-'
      'status fixture correctly (ADR-020 §2, replacing the single combined '
      'list)', () {
    testWidgets('PENDING (the default tab) shows only the pending requester', (
      tester,
    ) async {
      final service = ScriptedMeetupService(
        myMeetups: (hosted: [_hostedMeetup()], requested: const []),
        meetupRequests: [
          _request(
            id: 'r-pending',
            requesterFullName: 'Pending Person',
            status: MeetupRequestStatus.pending,
          ),
          _request(
            id: 'r-accepted',
            requesterFullName: 'Accepted Person',
            status: MeetupRequestStatus.accepted,
          ),
          _request(
            id: 'r-rejected',
            requesterFullName: 'Rejected Person',
            status: MeetupRequestStatus.rejected,
          ),
          _request(
            id: 'r-withdrawn',
            requesterFullName: 'Withdrawn Person',
            status: MeetupRequestStatus.withdrawn,
            withdrawalNote: 'Something came up',
          ),
        ],
        meetupDetail: _hostedMeetup(),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Colombo Fort Cafe'));
      await tester.pumpAndSettle();

      expect(find.text('Pending Person'), findsOneWidget);
      expect(find.text('Accepted Person'), findsNothing);
      expect(find.text('Rejected Person'), findsNothing);
      expect(find.text('Withdrawn Person'), findsNothing);
    });

    testWidgets('ACCEPTED shows only the accepted requester', (tester) async {
      final service = ScriptedMeetupService(
        myMeetups: (hosted: [_hostedMeetup()], requested: const []),
        meetupRequests: [
          _request(
            id: 'r-pending',
            requesterFullName: 'Pending Person',
            status: MeetupRequestStatus.pending,
          ),
          _request(
            id: 'r-accepted',
            requesterFullName: 'Accepted Person',
            status: MeetupRequestStatus.accepted,
          ),
          _request(
            id: 'r-rejected',
            requesterFullName: 'Rejected Person',
            status: MeetupRequestStatus.rejected,
          ),
        ],
        meetupDetail: _hostedMeetup(),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Colombo Fort Cafe'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('ACCEPTED'));
      await tester.pumpAndSettle();

      expect(find.text('Accepted Person'), findsOneWidget);
      expect(find.text('Pending Person'), findsNothing);
      expect(find.text('Rejected Person'), findsNothing);
    });

    testWidgets('REJECTED shows both the rejected and the withdrawn requester, '
        'the latter with its withdrawal note visible', (tester) async {
      final service = ScriptedMeetupService(
        myMeetups: (hosted: [_hostedMeetup()], requested: const []),
        meetupRequests: [
          _request(
            id: 'r-pending',
            requesterFullName: 'Pending Person',
            status: MeetupRequestStatus.pending,
          ),
          _request(
            id: 'r-rejected',
            requesterFullName: 'Rejected Person',
            status: MeetupRequestStatus.rejected,
          ),
          _request(
            id: 'r-withdrawn',
            requesterFullName: 'Withdrawn Person',
            status: MeetupRequestStatus.withdrawn,
            withdrawalNote: 'Something came up',
          ),
        ],
        meetupDetail: _hostedMeetup(),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Colombo Fort Cafe'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('REJECTED'));
      await tester.pumpAndSettle();

      expect(find.text('Rejected Person'), findsOneWidget);
      expect(find.text('Withdrawn Person'), findsOneWidget);
      expect(find.text('"Something came up"'), findsOneWidget);
      expect(find.text('Pending Person'), findsNothing);
    });

    // The rating block on this tab exists for ONE reason (ADR-020 §4): a
    // host may rate a requester who withdrew. It is not the post-meetup
    // rating flow, which lives on the meetup itself.
    testWidgets('the withdrawal-rating block stays hidden when nobody '
        'withdrew — even though the completed meetup has people the host '
        'can rate elsewhere', (tester) async {
      final service = ScriptedMeetupService(
        myMeetups: (hosted: [_hostedMeetup()], requested: const []),
        meetupRequests: [
          _request(
            id: 'r-rejected',
            requesterFullName: 'Rejected Person',
            status: MeetupRequestStatus.rejected,
          ),
        ],
        // Ratable because the meetup HAPPENED, not because they withdrew.
        ratableParticipants: const [
          RatableParticipant(
            userId: 'attendee-1',
            fullName: 'Attended Person',
            trustLevel: 2,
          ),
        ],
        meetupDetail: _hostedMeetup(),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Colombo Fort Cafe'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('REJECTED'));
      await tester.pumpAndSettle();

      expect(
        find.text('RATE WHO YOU MET'),
        findsNothing,
        reason:
            'a tab reading "No rejected or withdrawn requests." offering '
            'someone to rate contradicts itself',
      );
      expect(find.text('Attended Person'), findsNothing);
    });

    testWidgets('it offers only the requester who withdrew, not everyone the '
        'host could rate on this meetup', (tester) async {
      final service = ScriptedMeetupService(
        myMeetups: (hosted: [_hostedMeetup()], requested: const []),
        meetupRequests: [
          _request(
            id: 'r-withdrawn',
            requesterFullName: 'Withdrawn Person',
            status: MeetupRequestStatus.withdrawn,
          ),
        ],
        ratableParticipants: const [
          // requesterId == request id, per _request above.
          RatableParticipant(
            userId: 'r-withdrawn',
            fullName: 'Withdrawn Person',
            trustLevel: 2,
          ),
          RatableParticipant(
            userId: 'attendee-1',
            fullName: 'Attended Person',
            trustLevel: 2,
          ),
        ],
        meetupDetail: _hostedMeetup(),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Colombo Fort Cafe'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('REJECTED'));
      await tester.pumpAndSettle();

      expect(find.text('RATE WHO YOU MET'), findsOneWidget);
      // Once in the request list, once in the rating card.
      expect(find.text('Withdrawn Person'), findsNWidgets(2));
      expect(
        find.text('Attended Person'),
        findsNothing,
        reason:
            'they did not withdraw; rating them belongs to the '
            'post-meetup flow on the meetup itself',
      );
    });
  });

  group('Request card — requester name, trust level, and rating render '
      'correctly and survive a long name without breaking the row layout', () {
    testWidgets(
      'a long requester name wraps onto more lines instead of being cut — '
      'the trust badge and rating sit under it, always fully visible',
      (tester) async {
        const longName =
            'Maximilian Alexander Bartholomew Fitzgerald-Worthington III';
        final service = ScriptedMeetupService(
          myMeetups: (hosted: [_hostedMeetup()], requested: const []),
          meetupRequests: [_pendingRequest(requesterFullName: longName)],
          meetupDetail: _hostedMeetup(),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [meetupServiceProvider.overrideWithValue(service)],
            child: const MaterialApp(home: EventsPage()),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('VIEW REQUESTS'));
        await tester.pumpAndSettle();

        final text = tester.widget<Text>(find.text(longName));
        expect(text.overflow, isNot(TextOverflow.ellipsis));
        expect(text.maxLines, isNull);
        // Rendered taller than one line: it wrapped rather than clipped.
        final box = tester.getSize(find.text(longName));
        expect(box.height, greaterThan(20));
        expect(find.byType(TrustLevelBadge), findsOneWidget);
        expect(find.byType(StarRating), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('renders the real requester full name and trust level, not a '
        'placeholder — regression guard for the request card', (tester) async {
      final service = ScriptedMeetupService(
        myMeetups: (hosted: [_hostedMeetup()], requested: const []),
        meetupRequests: [
          _request(
            id: 'r-1',
            requesterFullName: 'Grace Hopper',
            status: MeetupRequestStatus.pending,
          ),
        ],
        meetupDetail: _hostedMeetup(),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Colombo Fort Cafe'));
      await tester.pumpAndSettle();

      expect(find.text('Grace Hopper'), findsOneWidget);
      expect(find.text('L2 Trust'), findsOneWidget);
    });
  });

  group('cursor pagination (2026-08-31 round-4 hardening)', () {
    testWidgets('the HOSTING tab requests a second page via hosted_cursor when '
        'scrolled near the bottom, appending its items', (tester) async {
      final firstPage = List.generate(
        10,
        (i) => _hostedMeetup(id: 'hosted-$i'),
      );
      final service = ScriptedMeetupService(
        myMeetups: (hosted: firstPage, requested: const []),
        myMeetupsHostedNextCursor: 'hosted-cursor-1',
        myMeetupsHostedHasMore: true,
        myMeetupsHostedPage2: [_hostedMeetup(id: 'hosted-page-2')],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(service.listMyMeetupsCallCount, 1);

      await tester.drag(find.byType(ListView), const Offset(0, -6000));
      await tester.pumpAndSettle();

      expect(service.listMyMeetupsCallCount, 2);
      expect(service.listMyMeetupsCalls.last.hostedCursor, 'hosted-cursor-1');
      expect(service.listMyMeetupsCalls.last.requestedCursor, isNull);
    });

    testWidgets(
      'the REQUESTED tab requests a second page via requested_cursor when '
      'scrolled near the bottom, independently of the hosted side',
      (tester) async {
        final firstPage = List.generate(
          10,
          (i) => _hostedMeetup(id: 'req-$i').copyWithRequestStatus(
            MeetupRequestStatus.pending,
            autoRejected: false,
          ),
        );
        final page2 = [
          _hostedMeetup(id: 'req-page-2').copyWithRequestStatus(
            MeetupRequestStatus.pending,
            autoRejected: false,
          ),
        ];
        final service = ScriptedMeetupService(
          myMeetups: (hosted: const [], requested: firstPage),
          myMeetupsRequestedNextCursor: 'requested-cursor-1',
          myMeetupsRequestedHasMore: true,
          myMeetupsRequestedPage2: page2,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [meetupServiceProvider.overrideWithValue(service)],
            child: const MaterialApp(home: EventsPage()),
          ),
        );
        await tester.pumpAndSettle();

        // RENAMED by the Home/Events restructure: the tab was 'REQUESTED'.
        await tester.tap(find.text('Requested Meetings'));
        await tester.pumpAndSettle();

        expect(service.listMyMeetupsCallCount, 1);

        await tester.drag(find.byType(ListView), const Offset(0, -6000));
        await tester.pumpAndSettle();

        expect(service.listMyMeetupsCallCount, 2);
        expect(
          service.listMyMeetupsCalls.last.requestedCursor,
          'requested-cursor-1',
        );
        expect(service.listMyMeetupsCalls.last.hostedCursor, isNull);
      },
    );
  });

  /// # NEW IN THE HOME/EVENTS RESTRUCTURE
  ///
  /// The page went from one level of tabs (HOSTING | REQUESTED) plus a pair
  /// of custom toggle buttons standing in for a second level, to two levels
  /// of real tabs:
  ///
  ///   My Meetings        -> Open meetups | History
  ///   Requested Meetings -> Open meetups | History
  ///
  /// The open/history filter itself is unchanged — still computed
  /// client-side over the already-fetched list. What is new is that there
  /// are four addressable cells, so all four are asserted, each with a
  /// fixture in every other cell to prove the filter is actually filtering
  /// rather than every cell happening to be empty.
  group('two levels of tabs', () {
    testWidgets(
      'defaults to My Meetings / Open meetups, and shows only that cell',
      (tester) async {
        await tester.pumpWidget(_eventsApp(_fourCellService()));
        await tester.pumpAndSettle();

        expect(find.text('EVENTS'), findsOneWidget);
        expect(find.text('My Meetings'), findsOneWidget);
        expect(find.text('Requested Meetings'), findsOneWidget);

        expect(find.text('Hosted Open Cafe'), findsOneWidget);
        expect(find.text('Hosted History Cafe'), findsNothing);
        expect(find.text('Requested Open Cafe'), findsNothing);
        expect(find.text('Requested History Cafe'), findsNothing);
      },
    );

    testWidgets('My Meetings / History shows the completed hosted meetup', (
      tester,
    ) async {
      await tester.pumpWidget(_eventsApp(_fourCellService()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();

      expect(find.text('Hosted History Cafe'), findsOneWidget);
      expect(find.text('Hosted Open Cafe'), findsNothing);
    });

    testWidgets(
      'Requested Meetings / Open meetups shows the requested open meetup — '
      'and the sub-tab resets to Open on the freshly built second list, '
      'rather than inheriting the first list\'s position',
      (tester) async {
        await tester.pumpWidget(_eventsApp(_fourCellService()));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Requested Meetings'));
        await tester.pumpAndSettle();

        expect(find.text('Requested Open Cafe'), findsOneWidget);
        expect(find.text('Requested History Cafe'), findsNothing);
        expect(find.text('Hosted Open Cafe'), findsNothing);
      },
    );

    testWidgets('Requested Meetings / History shows the cancelled requested '
        'meetup — cancelled counts as history alongside completed', (
      tester,
    ) async {
      await tester.pumpWidget(_eventsApp(_fourCellService()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Requested Meetings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();

      expect(find.text('Requested History Cafe'), findsOneWidget);
      expect(find.text('Requested Open Cafe'), findsNothing);
    });

    testWidgets(
      'each sub-tab has its own empty state rather than repeating the '
      'top-level tab\'s copy',
      (tester) async {
        await tester.pumpWidget(
          _eventsApp(
            ScriptedMeetupService(
              myMeetups: (hosted: const [], requested: const []),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Nothing on your calendar yet'), findsOneWidget);
        expect(find.text('HOST A MEETUP'), findsOneWidget);

        await tester.tap(find.text('History'));
        await tester.pumpAndSettle();

        expect(find.text('No past meetups yet'), findsOneWidget);
        expect(find.text('HOST A MEETUP'), findsNothing);
      },
    );

    testWidgets(
      'initialTab: 1 deep-links straight to Requested Meetings — kept '
      'through the rename because meetup_detail_page.dart still pushes this '
      'page that way',
      (tester) async {
        await tester.pumpWidget(_eventsApp(_fourCellService(), initialTab: 1));
        await tester.pumpAndSettle();

        expect(find.text('Requested Open Cafe'), findsOneWidget);
        expect(find.text('Hosted Open Cafe'), findsNothing);
      },
    );

    testWidgets(
      'the Open/History control is a pair of icon buttons, not a second '
      'TabBar — the page has exactly ONE TabBar (the top level), so the two '
      'levels cannot read as one four-item control',
      (tester) async {
        await tester.pumpWidget(_eventsApp(_fourCellService()));
        await tester.pumpAndSettle();

        expect(find.byType(TabBar), findsOneWidget);
        expect(find.byIcon(Icons.event_available_outlined), findsOneWidget);
        expect(find.byIcon(Icons.history_rounded), findsOneWidget);
      },
    );

    testWidgets(
      'NEITHER tab level swipes — this page sits inside AppShell\'s PageView, '
      'and the innermost horizontal scrollable would swallow the drag, '
      'making Events the one page you could not swipe out of',
      (tester) async {
        await tester.pumpWidget(_eventsApp(_fourCellService()));
        await tester.pumpAndSettle();

        expect(find.text('Hosted Open Cafe'), findsOneWidget);

        // A fling that WOULD have changed sub-tab before this fix.
        await tester.fling(
          find.byType(TabBarView).last,
          const Offset(-400, 0),
          1000,
        );
        await tester.pumpAndSettle();

        expect(find.text('Hosted Open Cafe'), findsOneWidget);
        expect(find.text('Hosted History Cafe'), findsNothing);

        // ...and the same at the top level.
        await tester.fling(
          find.byType(TabBarView).first,
          const Offset(-400, 0),
          1000,
        );
        await tester.pumpAndSettle();

        expect(find.text('Requested Open Cafe'), findsNothing);

        // Tapping still works — that is the intended way to switch now, and
        // both controls are permanently on screen.
        await tester.tap(find.text('History'));
        await tester.pumpAndSettle();
        expect(find.text('Hosted History Cafe'), findsOneWidget);
      },
    );

    testWidgets('initialTab: 0 is the default and lands on My Meetings', (
      tester,
    ) async {
      await tester.pumpWidget(_eventsApp(_fourCellService(), initialTab: 0));
      await tester.pumpAndSettle();

      expect(find.text('Hosted Open Cafe'), findsOneWidget);
      expect(find.text('Requested Open Cafe'), findsNothing);
    });
  });

  group('host actions on the Events tab', () {
    testWidgets('a live hosted meetup carries an explicit VIEW REQUESTS '
        'action that opens request management', (tester) async {
      final service = ScriptedMeetupService(
        myMeetups: (hosted: [_hostedMeetup()], requested: const []),
        meetupRequests: [_pendingRequest()],
        meetupDetail: _hostedMeetup(),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('VIEW REQUESTS'), findsOneWidget);
      await tester.tap(find.text('VIEW REQUESTS'));
      await tester.pumpAndSettle();

      expect(find.text('ACCEPT'), findsOneWidget);
    });

    testWidgets('a finished hosted meetup has no VIEW REQUESTS — there is '
        'nothing left to manage', (tester) async {
      final service = ScriptedMeetupService(
        myMeetups: (hosted: [_hostedMeetupFinished()], requested: const []),
        meetupDetail: _hostedMeetupFinished(),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('VIEW REQUESTS'), findsNothing);
    });

    testWidgets('tapping a requester on the request list opens their public '
        'profile, and the badges shown come from that profile', (tester) async {
      final service = ScriptedMeetupService(
        myMeetups: (hosted: [_hostedMeetup()], requested: const []),
        meetupRequests: [_pendingRequest(requesterFullName: 'Grace Hopper')],
        meetupDetail: _hostedMeetup(),
      );
      final auth = ImmediateAuthService()
        ..publicProfileFor = (id) => PublicProfile(
          id: id,
          fullName: 'Grace Hopper',
          trustLevel: 3,
          meetupsCompleted: 4,
          linkedInConnected: true,
        );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            meetupServiceProvider.overrideWithValue(service),
            authServiceProvider.overrideWithValue(auth),
          ],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('VIEW REQUESTS'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Grace Hopper'));
      await tester.pumpAndSettle();

      expect(find.byType(PublicProfilePage), findsOneWidget);
      expect(find.text('Professional'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
    });
  });

  group('history cards carry no request state', () {
    testWidgets('a finished requested meetup does not say YOU\'RE IN — it '
        'already happened', (tester) async {
      final finished = _requestedFinished(id: 'past-req');
      final service = ScriptedMeetupService(
        myMeetups: (hosted: const [], requested: [finished]),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Requested Meetings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();

      // The card IS there — its outcome chip proves it — without the
      // request-state text a live card would carry.
      expect(find.text('COMPLETED'), findsOneWidget);
      expect(find.text('YOU\'RE IN'), findsNothing);
    });
  });

  group('History outcome chips', () {
    Future<void> openRequestedHistory(WidgetTester tester) async {
      await tester.tap(find.text('Requested Meetings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
    }

    testWidgets('a finished meetup reads COMPLETED', (tester) async {
      final finished = _requestedFinished(id: 'done');
      final service = ScriptedMeetupService(
        myMeetups: (hosted: const [], requested: [finished]),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();
      await openRequestedHistory(tester);
      expect(find.text('COMPLETED'), findsOneWidget);
    });

    testWidgets('a cancelled meetup reads CANCELLED', (tester) async {
      final cancelled = _requestedFinished(
        id: 'cx',
        status: MeetupStatus.cancelled,
        cancellationReason: 'Sorry.',
      );
      final service = ScriptedMeetupService(
        myMeetups: (hosted: const [], requested: [cancelled]),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();
      await openRequestedHistory(tester);
      expect(find.text('CANCELLED'), findsOneWidget);
      expect(find.text('COMPLETED'), findsNothing);
    });

    testWidgets('a withdrawn request reads WITHDRAWN', (tester) async {
      final withdrawn = _requestedFinished(
        id: 'wd',
        myRequestStatus: MeetupRequestStatus.withdrawn,
      );
      final service = ScriptedMeetupService(
        myMeetups: (hosted: const [], requested: [withdrawn]),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(home: EventsPage()),
        ),
      );
      await tester.pumpAndSettle();
      await openRequestedHistory(tester);
      expect(find.text('WITHDRAWN'), findsOneWidget);
      expect(find.text('COMPLETED'), findsNothing);
    });
  });
}

extension on Meetup {
  Meetup copyWithRequestStatus(
    MeetupRequestStatus status, {
    required bool autoRejected,
  }) => Meetup(
    id: id,
    hostUserId: hostUserId,
    hostFullName: hostFullName,
    hostTrustLevel: hostTrustLevel,
    intent: intent,
    windowStart: windowStart,
    windowEnd: windowEnd,
    locationLat: locationLat,
    locationLng: locationLng,
    locationLabel: locationLabel,
    capacity: capacity,
    acceptedCount: acceptedCount,
    status: MeetupStatus.open,
    createdAt: createdAt,
    isHostedByMe: false,
    myRequestStatus: status,
    myRequestAutoRejected: autoRejected,
  );
}
