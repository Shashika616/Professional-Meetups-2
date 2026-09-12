import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/features/safety/manage_trusted_contacts_page.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/features/meetups/meetup_detail_page.dart';
import 'package:professional_connections_platform/features/meetups/review/experience_scale.dart';

import 'support/scripted_meetup_service.dart';

// Every meetup requires a real window now, "today" included (ADR-016) — no
// more nullable scheduledFor/isToday special case. windowStart defaults to
// already-started so tests that don't care about the check-in time gate
// (e.g. the checklist-first test below) aren't accidentally blocked by it.
// Named "accepted" since it was written, but it did not actually SAY so until
// 2026-09-10: myRequestStatus was left null, i.e. "this viewer never requested
// to join". Every test here then read as a participant's view while describing
// a stranger's, which is exactly why the suite could not see the bug where a
// non-participant was offered the review - there was no fixture difference
// between the two cases to catch.
//
// Defaulting to accepted makes the fixture mean what its name claims. A test
// that wants the stranger's view now has to ask for it explicitly.
Meetup _acceptedMeetup({
  DateTime? windowStart,
  bool isHostedByMe = false,
  MeetupRequestStatus? myRequestStatus = MeetupRequestStatus.accepted,
  MeetupStatus status = MeetupStatus.open,
  String? cancellationReason,
}) => Meetup(
  id: 'meetup-1',
  hostUserId: 'host-1',
  hostFullName: 'Grace Hopper',
  hostTrustLevel: 3,
  intent: IntentType.coffee,
  windowStart:
      windowStart ?? DateTime.now().subtract(const Duration(minutes: 15)),
  windowEnd:
      (windowStart ?? DateTime.now().subtract(const Duration(minutes: 15))).add(
        const Duration(hours: 2),
      ),
  locationLat: 6.9271,
  locationLng: 79.8612,
  locationLabel: 'Colombo Fort Cafe',
  capacity: 4,
  acceptedCount: 1,
  status: status,
  cancellationReason: cancellationReason,
  createdAt: DateTime.now(),
  isHostedByMe: isHostedByMe,
  myRequestStatus: myRequestStatus,
);

void main() {
  testWidgets('renders on the app background image — this page is reached via '
      'Navigator.push, not one of AppShell\'s own bottom-nav tabs, so it '
      'needs its own AppBackground rather than inheriting AppShell\'s', (
    tester,
  ) async {
    final service = ScriptedMeetupService(meetupDetail: _acceptedMeetup());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [meetupServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(home: MeetupDetailPage(meetupId: 'meetup-1')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppBackground), findsOneWidget);
  });

  group('Close Meetup (ADR-016) — host-only, only after the window starts', () {
    testWidgets('hidden for a non-host', (tester) async {
      final service = ScriptedMeetupService(
        meetupDetail: _acceptedMeetup(isHostedByMe: false),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(
            home: MeetupDetailPage(meetupId: 'meetup-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('CLOSE MEETUP'), findsNothing);
    });

    testWidgets('hidden for the host before the window has started', (
      tester,
    ) async {
      final service = ScriptedMeetupService(
        meetupDetail: _acceptedMeetup(
          windowStart: DateTime.now().add(const Duration(hours: 1)),
          isHostedByMe: true,
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(
            home: MeetupDetailPage(meetupId: 'meetup-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('CLOSE MEETUP'), findsNothing);
    });

    testWidgets('shown for the host once the window has started, behind a '
        'confirmation dialog, and calls closeMeetup only on Confirm '
        '(ADR-016 addendum, 2026-08-20)', (tester) async {
      final closed = _acceptedMeetup(
        isHostedByMe: true,
      ).copyWith(status: MeetupStatus.completed, closedAt: DateTime.now());
      final service = ScriptedMeetupService(
        meetupDetail: _acceptedMeetup(isHostedByMe: true),
      )..closeMeetupResult = closed;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(
            home: MeetupDetailPage(meetupId: 'meetup-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('CLOSE MEETUP'), findsOneWidget);

      await tester.tap(find.text('CLOSE MEETUP'));
      await tester.pumpAndSettle();

      // Dialog is up — the API must not have been called yet.
      expect(find.text('Mark this meetup as done?'), findsOneWidget);
      expect(service.lastCloseMeetupId, isNull);

      await tester.tap(find.text('CONFIRM'));
      await tester.pumpAndSettle();

      expect(service.lastCloseMeetupId, 'meetup-1');
      expect(find.text('Meetup closed.'), findsOneWidget);
      // The button reflects the server's authoritative response (status
      // now COMPLETED) rather than a locally-guessed state.
      expect(find.text('CLOSE MEETUP'), findsNothing);

      // Let the toast's hold timer + dismiss animation fully finish so
      // its OverlayEntry doesn't outlive this test's widget tree — the
      // ToastService's OverlayEntry is a static singleton shared across
      // every test in this isolate.
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets(
      'dismissing the confirmation dialog (CANCEL) does not call the API',
      (tester) async {
        final service = ScriptedMeetupService(
          meetupDetail: _acceptedMeetup(isHostedByMe: true),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [meetupServiceProvider.overrideWithValue(service)],
            child: const MaterialApp(
              home: MeetupDetailPage(meetupId: 'meetup-1'),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('CLOSE MEETUP'));
        await tester.pumpAndSettle();

        // The dialog's own dismiss button is also labelled CANCEL — this
        // targets it specifically among the two 'CANCEL' texts now on
        // screen (the dialog's, and the CANCEL MEETUP button underneath).
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('CANCEL'),
          ),
        );
        await tester.pumpAndSettle();

        expect(service.lastCloseMeetupId, isNull);
        // Still showing the un-actioned button — nothing changed.
        expect(find.text('CLOSE MEETUP'), findsOneWidget);
      },
    );
  });

  group('Cancel Meetup (ADR-016 addendum, 2026-08-20; widened by ADR-020 §3 '
      'to allow cancelling with accepted participants) — host-only', () {
    testWidgets('hidden for a non-host', (tester) async {
      final service = ScriptedMeetupService(
        meetupDetail: _acceptedMeetup(isHostedByMe: false),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(
            home: MeetupDetailPage(meetupId: 'meetup-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('CANCEL MEETUP'), findsNothing);
    });

    testWidgets('shown for the host, behind a confirmation dialog, and calls '
        'cancelMeetup only on Confirm', (tester) async {
      final draft = Meetup(
        id: 'meetup-1',
        hostUserId: 'host-1',
        hostFullName: 'Grace Hopper',
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
      final service = ScriptedMeetupService(meetupDetail: draft);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(
            home: MeetupDetailPage(meetupId: 'meetup-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('CANCEL MEETUP'), findsOneWidget);

      await tester.tap(find.text('CANCEL MEETUP'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Cancel this meetup?'), findsOneWidget);
      expect(service.lastCancelMeetupId, isNull);

      await tester.enterText(find.byType(TextField), 'Something came up');
      await tester.pumpAndSettle();

      // The dialog's title also reads "CANCEL MEETUP" — only the
      // action is a TextButton, so that's what disambiguates it.
      await tester.tap(find.widgetWithText(TextButton, 'CANCEL MEETUP'));
      await tester.pumpAndSettle();

      expect(service.lastCancelMeetupId, 'meetup-1');
      expect(service.lastCancelMeetupReason, 'Something came up');
      expect(find.text('Meetup cancelled.'), findsOneWidget);
      expect(find.text('CANCEL MEETUP'), findsNothing);
      expect(find.text('CLOSE MEETUP'), findsNothing);

      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('dismissing the dialog (BACK) does not call the API', (
      tester,
    ) async {
      final draft = Meetup(
        id: 'meetup-1',
        hostUserId: 'host-1',
        hostFullName: 'Grace Hopper',
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
      final service = ScriptedMeetupService(meetupDetail: draft);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(
            home: MeetupDetailPage(meetupId: 'meetup-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('CANCEL MEETUP'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('BACK'));
      await tester.pumpAndSettle();

      expect(service.lastCancelMeetupId, isNull);
      expect(find.text('CANCEL MEETUP'), findsOneWidget);
    });

    testWidgets(
      'still shown even once the meetup has an accepted participant — '
      'ADR-020 §3 widened the backend to allow this instead of rejecting it',
      (tester) async {
        final service = ScriptedMeetupService(
          meetupDetail: _acceptedMeetup(isHostedByMe: true),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [meetupServiceProvider.overrideWithValue(service)],
            child: const MaterialApp(
              home: MeetupDetailPage(meetupId: 'meetup-1'),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('CANCEL MEETUP'), findsOneWidget);
        expect(find.text('CLOSE MEETUP'), findsOneWidget);
      },
    );
  });

  group('Withdraw Request (ADR-020 §4) — requester-side, both pending and '
      'accepted requests are withdrawable', () {
    testWidgets('hidden when the viewer has no request on this meetup', (
      tester,
    ) async {
      final service = ScriptedMeetupService(meetupDetail: _acceptedMeetup());

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(
            home: MeetupDetailPage(meetupId: 'meetup-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('WITHDRAW REQUEST'), findsNothing);
      expect(find.text('CANCEL REQUEST'), findsNothing);
    });

    testWidgets(
      'a PENDING request is cancelled, not withdrawn: a plain confirmation '
      'with no note, and the request is taken back only on confirm',
      (tester) async {
        final pending = Meetup(
          id: 'meetup-1',
          hostUserId: 'host-1',
          hostFullName: 'Grace Hopper',
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
          myRequestStatus: MeetupRequestStatus.pending,
          myRequestId: 'request-1',
        );
        final service = ScriptedMeetupService(meetupDetail: pending);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [meetupServiceProvider.overrideWithValue(service)],
            child: const MaterialApp(
              home: MeetupDetailPage(meetupId: 'meetup-1'),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('CANCEL REQUEST'), findsOneWidget);
        expect(find.text('WITHDRAW REQUEST'), findsNothing);

        await tester.tap(find.text('CANCEL REQUEST'));
        await tester.pumpAndSettle();
        expect(service.lastWithdrawRequestId, isNull); // dialog first
        // No note: the host has not acted and is not told anything.
        expect(find.byType(TextField), findsNothing);
        expect(find.textContaining('nothing is sent to them'), findsOneWidget);

        // KEEP IT leaves everything as it was.
        await tester.tap(find.text('KEEP IT'));
        await tester.pumpAndSettle();
        expect(service.lastWithdrawRequestId, isNull);

        await tester.tap(find.text('CANCEL REQUEST'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'CANCEL REQUEST'));
        await tester.pumpAndSettle();

        expect(service.lastWithdrawRequestId, 'request-1');
        expect(service.lastWithdrawRequestNote, isNull);
        expect(find.text('Request cancelled.'), findsOneWidget);
        expect(find.text('Request withdrawn.'), findsNothing);

        await tester.pump(const Duration(seconds: 3));
      },
    );

    testWidgets('an accepted request is also withdrawable', (tester) async {
      final accepted = Meetup(
        id: 'meetup-1',
        hostUserId: 'host-1',
        hostFullName: 'Grace Hopper',
        hostTrustLevel: 3,
        intent: IntentType.coffee,
        windowStart: DateTime.now().add(const Duration(hours: 1)),
        windowEnd: DateTime.now().add(const Duration(hours: 3)),
        locationLat: 6.9271,
        locationLng: 79.8612,
        locationLabel: 'Colombo Fort Cafe',
        capacity: 4,
        acceptedCount: 1,
        status: MeetupStatus.open,
        createdAt: DateTime.now(),
        myRequestStatus: MeetupRequestStatus.accepted,
        myRequestId: 'request-2',
      );
      final service = ScriptedMeetupService(meetupDetail: accepted);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(
            home: MeetupDetailPage(meetupId: 'meetup-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('WITHDRAW REQUEST'), findsOneWidget);
    });

    testWidgets(
      'the withdrawal note is optional — confirming with an empty note '
      'still withdraws',
      (tester) async {
        final pending = Meetup(
          id: 'meetup-1',
          hostUserId: 'host-1',
          hostFullName: 'Grace Hopper',
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
          myRequestStatus: MeetupRequestStatus.accepted,
          myRequestId: 'request-1',
        );
        final service = ScriptedMeetupService(meetupDetail: pending);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [meetupServiceProvider.overrideWithValue(service)],
            child: const MaterialApp(
              home: MeetupDetailPage(meetupId: 'meetup-1'),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('WITHDRAW REQUEST'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'WITHDRAW'));
        await tester.pumpAndSettle();

        expect(service.lastWithdrawRequestId, 'request-1');
        expect(service.lastWithdrawRequestNote, isNull);

        await tester.pump(const Duration(seconds: 3));
      },
    );
  });

  group('a finished meetup is a different page', () {
    Future<void> pumpPast(
      WidgetTester tester,
      ScriptedMeetupService service,
    ) async {
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(
            home: MeetupDetailPage(meetupId: 'meetup-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Meetup pastMeetup() => _acceptedMeetup(
      windowStart: DateTime.now().subtract(const Duration(hours: 3)),
    );

    testWidgets('it drops everything about GETTING to the meetup', (
      tester,
    ) async {
      await pumpPast(
        tester,
        ScriptedMeetupService(
          meetupDetail: pastMeetup(),
          safetyState: const SafetyState(meetupId: 'meetup-1'),
        ),
      );

      // All of this exists to help someone arrive at a meetup, and offering
      // it after the fact was the bug — a WITHDRAW REQUEST for an evening
      // that already finished.
      expect(find.text('WITHDRAW REQUEST'), findsNothing);
      expect(find.text('SAFETY GATE'), findsNothing);
      expect(find.text('I UNDERSTAND'), findsNothing);
      expect(find.text('TELL SOMEONE'), findsNothing);
      expect(find.text('How did it go?'), findsNothing);
    });

    testWidgets('it keeps what a past meetup is still about — the details '
        'and the location', (tester) async {
      await pumpPast(
        tester,
        ScriptedMeetupService(
          meetupDetail: pastMeetup(),
          safetyState: const SafetyState(meetupId: 'meetup-1'),
        ),
      );

      expect(find.text('Colombo Fort Cafe'), findsOneWidget);
      // The two full-width outlined bars became a pair of icon tiles sharing
      // one row, so the label lost its now-redundant VIEW prefix.
      expect(find.text('LOCATION'), findsOneWidget);
    });

    testWidgets('an unreviewed past meetup offers the review — this is what '
        'keeps it reachable after the home card lapses', (tester) async {
      await pumpPast(
        tester,
        ScriptedMeetupService(
          meetupDetail: pastMeetup(),
          safetyState: const SafetyState(meetupId: 'meetup-1'),
        ),
      );

      expect(
        find.text('Share your thoughts about this meetup'),
        findsOneWidget,
      );

      await tester.tap(find.text('START REVIEW'));
      await tester.pumpAndSettle();
      expect(find.text('How was your experience?'), findsOneWidget);
    });

    testWidgets('finishing the review replaces the prompt with the result, '
        'right there on the page', (tester) async {
      late final ScriptedMeetupService service;
      service =
          ScriptedMeetupService(
              meetupDetail: pastMeetup(),
              safetyState: const SafetyState(meetupId: 'meetup-1'),
            )
            ..onSubmitReview = () => service.meetupReview = const MeetupReview(
              completed: true,
              overallScore: 3,
            );
      await pumpPast(tester, service);

      expect(find.text('START REVIEW'), findsOneWidget);
      await tester.tap(find.text('START REVIEW'));
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
        reason: 'the prompt outlived the review that answered it',
      );
      expect(find.text('Okay'), findsOneWidget);
    });

    testWidgets('a reviewed meetup shows the scores that were given, as '
        'static stars — ratings are immutable, so a picker would be a lie', (
      tester,
    ) async {
      await pumpPast(
        tester,
        ScriptedMeetupService(
            meetupDetail: pastMeetup(),
            safetyState: const SafetyState(meetupId: 'meetup-1'),
          )
          ..meetupReview = const MeetupReview(
            completed: true,
            overallScore: 5,
            notes: 'Genuinely useful.',
            participants: [
              ReviewedParticipant(
                userId: 'host-1',
                fullName: 'Grace Hopper',
                score: 4,
                traits: ['great_listener'],
              ),
            ],
          ),
      );

      expect(find.text('YOUR REVIEW'), findsOneWidget);
      expect(find.text('Excellent'), findsOneWidget);
      expect(find.text('"Genuinely useful."'), findsOneWidget);
      expect(find.text('HOW YOU RATED THEM'), findsOneWidget);
      expect(find.text('Grace Hopper'), findsOneWidget);
      // Stored as a key; rendered as words, without shipping a second copy
      // of the server's vocabulary.
      expect(find.text('Great listener'), findsOneWidget);
      // The prompt is gone once there is nothing left to ask for.
      expect(find.text('START REVIEW'), findsNothing);
    });
  });

  group('Non-participant Safety Gate visibility (ADR-024 §3) — the actual '
      'authorization fix, surfaced client-side', () {
    testWidgets(
      'a caller who is not this meetup\'s host or an accepted requester '
      'sees no Safety Gate section at all, and no error is shown',
      (tester) async {
        // ScriptedMeetupService.getSafetyState throws
        // MeetupForbiddenException when no safetyState is configured —
        // exactly what the real backend now does for a non-participant
        // (ADR-024 §3).
        final service = ScriptedMeetupService(meetupDetail: _acceptedMeetup());

        await tester.pumpWidget(
          ProviderScope(
            overrides: [meetupServiceProvider.overrideWithValue(service)],
            child: const MaterialApp(
              home: MeetupDetailPage(meetupId: 'meetup-1'),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('SAFETY GATE'), findsNothing);
        expect(find.text('CHECK IN'), findsNothing);
        // The page itself still loaded fine — Forbidden on the safety
        // fetch alone must not surface as a page-level load error.
        expect(
          find.text('Something went wrong. Please try again.'),
          findsNothing,
        );
      },
    );
  });

  /// # TELL A TRUSTED CONTACT
  ///
  /// Replaces a "Share live location" switch bound to a boolean nothing
  /// read — the app said it was sharing the user's location and shared it
  /// with nobody. These tests are about the two things that made the old
  /// version untrustworthy: that something is actually sent, and that the
  /// user can see afterwards that it was.
  group('tell a trusted contact', () {
    Widget app(
      ScriptedMeetupService service, {
      required List<TrustedContact> contacts,
    }) => ProviderScope(
      overrides: [
        meetupServiceProvider.overrideWithValue(service),
        trustedContactsProvider.overrideWith((ref) async => contacts),
      ],
      child: const MaterialApp(home: MeetupDetailPage(meetupId: 'meetup-1')),
    );

    const amma = TrustedContact(
      id: 'contact-1',
      name: 'Amma',
      phoneNumber: '+94771111111',
      email: '',
    );
    const friend = TrustedContact(
      id: 'contact-2',
      name: 'Friend',
      phoneNumber: '+94772222222',
      email: '',
    );

    testWidgets('the old live-location switch is gone', (tester) async {
      final service = ScriptedMeetupService(
        meetupDetail: _acceptedMeetup(),
        safetyState: const SafetyState(meetupId: 'meetup-1'),
      );

      await tester.pumpWidget(app(service, contacts: const [amma]));
      await tester.pumpAndSettle();

      expect(
        find.text('Share live location'),
        findsNothing,
        reason: 'it promised tracking the app never did',
      );
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Tell a trusted contact'), findsWidgets);
    });

    testWidgets(
      'picking contacts sends exactly those ids, and the screen then shows '
      'that it happened',
      (tester) async {
        final service = ScriptedMeetupService(
          meetupDetail: _acceptedMeetup(),
          safetyState: const SafetyState(meetupId: 'meetup-1'),
        );

        await tester.pumpWidget(app(service, contacts: const [amma, friend]));
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.text('TELL SOMEONE'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('TELL SOMEONE'));
        await tester.pumpAndSettle();

        // Nothing selected yet — the confirm must not be usable.
        final button = tester.widget<PrimaryButton>(
          find.widgetWithText(PrimaryButton, 'SHARE THIS MEETUP'),
        );
        expect(button.onPressed, isNull);

        await tester.tap(find.text('Amma'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('SHARE THIS MEETUP'));
        await tester.pumpAndSettle();

        expect(service.sharedContactIds, [
          'contact-1',
        ], reason: 'only the picked contact, and by id');
        expect(find.text('Told 1 trusted contact'), findsOneWidget);
      },
    );

    testWidgets('SELECT ALL picks every contact', (tester) async {
      final service = ScriptedMeetupService(
        meetupDetail: _acceptedMeetup(),
        safetyState: const SafetyState(meetupId: 'meetup-1'),
      );

      await tester.pumpWidget(app(service, contacts: const [amma, friend]));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('TELL SOMEONE'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('TELL SOMEONE'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SELECT ALL'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SHARE THIS MEETUP'));
      await tester.pumpAndSettle();

      expect(service.sharedContactIds, containsAll(['contact-1', 'contact-2']));
      expect(find.text('Told 2 trusted contacts'), findsOneWidget);
    });

    testWidgets(
      'a contact who already knows is shown as told and cannot be re-picked '
      '— pressing share again must not text them twice',
      (tester) async {
        final service = ScriptedMeetupService(
          meetupDetail: _acceptedMeetup(),
          safetyState: const SafetyState(
            meetupId: 'meetup-1',
            sharedWithContactIds: ['contact-1'],
          ),
        );

        await tester.pumpWidget(app(service, contacts: const [amma, friend]));
        await tester.pumpAndSettle();

        // The prior share is visible without reopening anything.
        expect(find.text('Told 1 trusted contact'), findsOneWidget);

        await tester.ensureVisible(find.text('TELL SOMEONE ELSE'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('TELL SOMEONE ELSE'));
        await tester.pumpAndSettle();

        expect(find.text('Already told'), findsOneWidget);

        // Tapping the already-told row selects nothing.
        await tester.tap(find.text('Amma'));
        await tester.pumpAndSettle();
        final button = tester.widget<PrimaryButton>(
          find.widgetWithText(PrimaryButton, 'SHARE THIS MEETUP'),
        );
        expect(button.onPressed, isNull);
      },
    );

    testWidgets(
      'with no contacts at all the sheet routes to the page that fixes that, '
      'rather than being a dead end',
      (tester) async {
        final service = ScriptedMeetupService(
          meetupDetail: _acceptedMeetup(),
          safetyState: const SafetyState(meetupId: 'meetup-1'),
        );

        await tester.pumpWidget(app(service, contacts: const []));
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.text('TELL SOMEONE'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('TELL SOMEONE'));
        await tester.pumpAndSettle();

        expect(find.textContaining('not added anyone yet'), findsOneWidget);

        await tester.tap(find.text('ADD A TRUSTED CONTACT'));
        await tester.pumpAndSettle();

        expect(find.byType(ManageTrustedContactsPage), findsOneWidget);
      },
    );

    testWidgets('a failed share surfaces the error and claims nothing', (
      tester,
    ) async {
      final service = ScriptedMeetupService(
        meetupDetail: _acceptedMeetup(),
        safetyState: const SafetyState(meetupId: 'meetup-1'),
      )..shareWithContactsError = const MeetupNetworkException('SMS is down');

      await tester.pumpWidget(app(service, contacts: const [amma]));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('TELL SOMEONE'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('TELL SOMEONE'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Amma'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SHARE THIS MEETUP'));
      await tester.pumpAndSettle();

      expect(find.text('SMS is down'), findsOneWidget);
      expect(
        find.textContaining('Told '),
        findsNothing,
        reason: 'a failed send must not report that anyone was told',
      );
    });
  });
  // The review flow belongs to the people who were actually on the meetup.
  //
  // This was reported from the deployed app: a user who had never requested to
  // join opened a finished meetup from the browse list and was shown the review
  // prompt. The page gated that section on `_isPastMeetup` ALONE - purely a
  // windowEnd-vs-now comparison, with no participation test - so every
  // authenticated viewer got it on every past meetup.
  //
  // The backend was never fooled: SubmitMeetupReview calls requireParticipant
  // and ListRatableParticipants returns an empty roster to a non-participant,
  // so no third-party review could ever have been written. That makes this a
  // trust-and-clarity defect rather than a data-integrity one - but offering a
  // control that cannot work, on someone else's meetup, is its own bug.
  //
  // Participation here mirrors the server's own definition exactly: the host,
  // or a requester whose request was ACCEPTED. Pending, rejected and withdrawn
  // are all non-participants.
  group('the review section is only for participants', () {
    testWidgets('hidden for a viewer who never requested to join', (
      tester,
    ) async {
      await _pumpDetail(tester, _endedMeetup());
      expect(find.text('Share your thoughts about this meetup'), findsNothing);
      expect(find.text('START REVIEW'), findsNothing);
    });

    testWidgets('hidden for a viewer whose request is only PENDING', (
      tester,
    ) async {
      await _pumpDetail(
        tester,
        _endedMeetup(myRequestStatus: MeetupRequestStatus.pending),
      );
      expect(find.text('Share your thoughts about this meetup'), findsNothing);
    });

    testWidgets('hidden for a viewer whose request was REJECTED', (
      tester,
    ) async {
      await _pumpDetail(
        tester,
        _endedMeetup(myRequestStatus: MeetupRequestStatus.rejected),
      );
      expect(find.text('Share your thoughts about this meetup'), findsNothing);
    });

    testWidgets('shown to an ACCEPTED participant', (tester) async {
      await _pumpDetail(
        tester,
        _endedMeetup(myRequestStatus: MeetupRequestStatus.accepted),
      );
      expect(
        find.text('Share your thoughts about this meetup'),
        findsOneWidget,
      );
    });

    testWidgets('shown to the host', (tester) async {
      await _pumpDetail(tester, _endedMeetup(isHostedByMe: true));
      expect(
        find.text('Share your thoughts about this meetup'),
        findsOneWidget,
      );
    });
  });

  // The other half of the same gate. A meetup that is over must not offer a way
  // to join it, and the un-swept `open` status above is precisely when that
  // could leak through: the browse list still carries the meetup, and a viewer
  // who is not a participant falls into neither the review branch nor any
  // participant branch.
  group('a finished meetup cannot be joined', () {
    testWidgets('no join action once the window has ended', (tester) async {
      await _pumpDetail(tester, _endedMeetup());
      expect(find.text('REQUEST TO JOIN'), findsNothing);
    });
  });

  group('a cancelled meetup on its own page', () {
    Meetup cancelled({required bool hostedByMe}) => _acceptedMeetup(
      windowStart: DateTime.now().add(const Duration(days: 1)),
      isHostedByMe: hostedByMe,
      myRequestStatus: hostedByMe ? null : MeetupRequestStatus.accepted,
      status: MeetupStatus.cancelled,
      cancellationReason: 'Venue closed unexpectedly.',
    );

    testWidgets('an accepted participant sees the banner with the reason '
        'and is invited to review the cancellation', (tester) async {
      final service = ScriptedMeetupService(
        meetupDetail: cancelled(hostedByMe: false),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(
            home: MeetupDetailPage(meetupId: 'meetup-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('CANCELLED BY THE HOST'), findsOneWidget);
      expect(
        find.text('\u201CVenue closed unexpectedly.\u201D'),
        findsOneWidget,
      );
      expect(
        find.text('Share your thoughts on this cancellation'),
        findsOneWidget,
      );
    });

    testWidgets('the host who cancelled sees the banner but is not asked '
        'to review their own cancellation', (tester) async {
      final service = ScriptedMeetupService(
        meetupDetail: cancelled(hostedByMe: true),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(
            home: MeetupDetailPage(meetupId: 'meetup-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('CANCELLED BY THE HOST'), findsOneWidget);
      expect(find.textContaining('Share your thoughts'), findsNothing);
    });
  });
}

// A meetup whose window has ENDED but whose status is still `open`, because
// the server-side auto-close sweep has not run yet. That is not a contrived
// state: on 2026-09-10 a production meetup whose window ended at 11:15 was
// not closed until 13:08 - 1h53m late - because Cloud Run had scaled to zero
// and the lifecycle poller only advances while a container exists. Any fix
// here has to hold in exactly that window, so the fixture reproduces it.
Meetup _endedMeetup({
  bool isHostedByMe = false,
  MeetupRequestStatus? myRequestStatus,
}) => Meetup(
  id: 'meetup-1',
  hostUserId: 'host-1',
  hostFullName: 'Grace Hopper',
  hostTrustLevel: 3,
  intent: IntentType.coffee,
  windowStart: DateTime.now().subtract(const Duration(hours: 4)),
  windowEnd: DateTime.now().subtract(const Duration(hours: 2)),
  locationLat: 6.9271,
  locationLng: 79.8612,
  locationLabel: 'Colombo Fort Cafe',
  capacity: 4,
  acceptedCount: 1,
  status: MeetupStatus.open,
  createdAt: DateTime.now().subtract(const Duration(days: 1)),
  isHostedByMe: isHostedByMe,
  myRequestStatus: myRequestStatus,
);

Future<void> _pumpDetail(WidgetTester tester, Meetup meetup) async {
  final service = ScriptedMeetupService(
    meetupDetail: meetup,
    safetyState: const SafetyState(meetupId: 'meetup-1'),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [meetupServiceProvider.overrideWithValue(service)],
      child: const MaterialApp(home: MeetupDetailPage(meetupId: 'meetup-1')),
    ),
  );
  await tester.pumpAndSettle();
}
