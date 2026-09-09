import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/meetup_status_badge.dart';
import 'package:professional_connections_platform/features/meetups/events_page.dart';

import 'support/scripted_meetup_service.dart';
import 'package:professional_connections_platform/features/meetups/meetup_detail_page.dart';

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

    expect(
      tester.widget<MeetupStatusBadge>(find.byType(MeetupStatusBadge)).status,
      MeetupStatus.open,
    );
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
      'a long requester name ellipsizes on one line instead of wrapping or '
      'clipping mid-character — the trust level badge and star rating '
      'next to it must stay fully visible regardless of name length',
      (tester) async {
        final service = ScriptedMeetupService(
          myMeetups: (hosted: [_hostedMeetup()], requested: const []),
          meetupRequests: [
            _request(
              id: 'r-1',
              requesterFullName:
                  'Alexandria Constantinopoulos-Weatherington the Third',
              status: MeetupRequestStatus.pending,
            ),
          ],
          meetupDetail: _hostedMeetup(),
        );

        // An iPhone-SE-class width — the narrowest real device class this
        // app targets (same width used elsewhere in this suite for
        // overflow regressions) — is where a missing overflow/maxLines
        // setting would actually bite.
        tester.view.physicalSize = const Size(375, 812);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [meetupServiceProvider.overrideWithValue(service)],
            child: const MaterialApp(home: EventsPage()),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Colombo Fort Cafe'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);

        final nameText = tester.widget<Text>(
          find.text('Alexandria Constantinopoulos-Weatherington the Third'),
        );
        expect(
          nameText.overflow,
          TextOverflow.ellipsis,
          reason: 'a long name must ellipsize, not silently clip or wrap',
        );
        expect(
          nameText.maxLines,
          1,
          reason:
              'without this, a long name can wrap to a second line and '
              'push the row out of vertical alignment with the trust '
              'badge/rating next to it',
        );

        // The trailing trust-level badge and rating must still be present
        // and readable — not squeezed out or hidden by the long name.
        expect(find.text('L2'), findsOneWidget);
        expect(find.text('New'), findsOneWidget);
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
      expect(find.text('L2'), findsOneWidget);
    });
  });

  group(
    'ACCEPTED tab — host visibility into Safety Gate status (ADR-024 §6)',
    () {
      testWidgets('an accepted requester who checked in shows "Checked in"', (
        tester,
      ) async {
        final service = ScriptedMeetupService(
          myMeetups: (hosted: [_hostedMeetup()], requested: const []),
          meetupRequests: [
            _request(
              id: 'r-checked-in',
              requesterFullName: 'Checked In Person',
              status: MeetupRequestStatus.accepted,
              checkedInAt: DateTime.now(),
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

        expect(find.text('Checked in'), findsOneWidget);
        expect(find.textContaining('Declined'), findsNothing);
        expect(find.text('Not checked in yet'), findsNothing);
      });

      testWidgets(
        'an accepted requester who declined shows "Declined: <reason>"',
        (tester) async {
          final service = ScriptedMeetupService(
            myMeetups: (hosted: [_hostedMeetup()], requested: const []),
            meetupRequests: [
              _request(
                id: 'r-declined',
                requesterFullName: 'Declined Person',
                status: MeetupRequestStatus.accepted,
                declinedAt: DateTime.now(),
                declineReason: 'running late, cannot make it',
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

          expect(
            find.text('Declined: running late, cannot make it'),
            findsOneWidget,
          );
          expect(find.text('Checked in'), findsNothing);
          expect(find.text('Not checked in yet'), findsNothing);
        },
      );

      testWidgets(
        'an accepted requester who hasn\'t touched the Safety Gate shows '
        '"Not checked in yet"',
        (tester) async {
          final service = ScriptedMeetupService(
            myMeetups: (hosted: [_hostedMeetup()], requested: const []),
            meetupRequests: [
              _request(
                id: 'r-untouched',
                requesterFullName: 'Untouched Person',
                status: MeetupRequestStatus.accepted,
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

          expect(find.text('Not checked in yet'), findsOneWidget);
          expect(find.text('Checked in'), findsNothing);
          expect(find.textContaining('Declined'), findsNothing);
        },
      );

      testWidgets(
        'a pending request never shows a Safety Gate status line — it '
        'never had a chance to touch one',
        (tester) async {
          final service = ScriptedMeetupService(
            myMeetups: (hosted: [_hostedMeetup()], requested: const []),
            meetupRequests: [
              _request(
                id: 'r-pending',
                requesterFullName: 'Pending Person',
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

          expect(find.text('Not checked in yet'), findsNothing);
          expect(find.text('Checked in'), findsNothing);
          expect(find.textContaining('Declined'), findsNothing);
        },
      );
    },
  );

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
      'each sub-tab has its own empty message — History says "Nothing here '
      'yet." rather than repeating the top-level tab\'s copy',
      (tester) async {
        await tester.pumpWidget(
          _eventsApp(
            ScriptedMeetupService(
              myMeetups: (hosted: const [], requested: const []),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('You aren\'t hosting any meetups yet.'),
          findsOneWidget,
        );

        await tester.tap(find.text('History'));
        await tester.pumpAndSettle();

        expect(find.text('Nothing here yet.'), findsOneWidget);
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
