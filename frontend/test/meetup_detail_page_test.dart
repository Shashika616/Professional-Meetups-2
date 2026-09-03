import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/features/meetups/meetup_detail_page.dart';

import 'support/scripted_meetup_service.dart';

// Every meetup requires a real window now, "today" included (ADR-016) — no
// more nullable scheduledFor/isToday special case. windowStart defaults to
// already-started so tests that don't care about the check-in time gate
// (e.g. the checklist-first test below) aren't accidentally blocked by it.
Meetup _acceptedMeetup({DateTime? windowStart, bool isHostedByMe = false}) =>
    Meetup(
      id: 'meetup-1',
      hostUserId: 'host-1',
      hostFullName: 'Grace Hopper',
      hostTrustLevel: 3,
      intent: IntentType.coffee,
      windowStart:
          windowStart ?? DateTime.now().subtract(const Duration(minutes: 15)),
      windowEnd:
          (windowStart ?? DateTime.now().subtract(const Duration(minutes: 15)))
              .add(const Duration(hours: 2)),
      locationLat: 6.9271,
      locationLng: 79.8612,
      locationLabel: 'Colombo Fort Cafe',
      capacity: 4,
      acceptedCount: 1,
      status: MeetupStatus.open,
      createdAt: DateTime.now(),
      isHostedByMe: isHostedByMe,
    );

void main() {
  testWidgets(
    'check-in is disabled with an explanatory message before the checklist is acknowledged',
    (tester) async {
      final service = ScriptedMeetupService(
        meetupDetail: _acceptedMeetup(),
        safetyState: const SafetyState(meetupId: 'meetup-1'),
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

      expect(find.text('CHECK IN'), findsNothing);
      expect(
        find.text('Acknowledge the checklist above first.'),
        findsOneWidget,
      );
    },
  );

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

  testWidgets(
    'check-in stays disabled with a time-window message once the checklist is acknowledged, '
    'more than 10 minutes before a scheduled meetup',
    (tester) async {
      final farFuture = DateTime.now().add(const Duration(hours: 3));
      final service = ScriptedMeetupService(
        meetupDetail: _acceptedMeetup(windowStart: farFuture),
        safetyState: const SafetyState(meetupId: 'meetup-1'),
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

      await tester.tap(find.text('I UNDERSTAND'));
      await tester.pumpAndSettle();

      expect(find.text('Checklist acknowledged'), findsOneWidget);
      expect(find.text('CHECK IN'), findsNothing);
      expect(
        find.text('Check-in opens 10 minutes before the meetup.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'check-in becomes enabled once acknowledged and within the 10-minute window',
    (tester) async {
      // The CHECK IN button sits below the fold at the default 800x600 test
      // surface (the Safety Gate section only renders once acknowledged) —
      // a taller surface keeps it within the hit-testable viewport instead
      // of relying on ensureVisible, which doesn't reliably scroll this
      // ListView far enough in a single pump.
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final soon = DateTime.now().add(const Duration(minutes: 5));
      final service = ScriptedMeetupService(
        meetupDetail: _acceptedMeetup(windowStart: soon),
        safetyState: const SafetyState(meetupId: 'meetup-1'),
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

      await tester.tap(find.text('I UNDERSTAND'));
      await tester.pumpAndSettle();

      expect(find.text('CHECK IN'), findsOneWidget);

      await tester.tap(find.text('CHECK IN'));
      await tester.pumpAndSettle();

      expect(find.text('Checked in'), findsOneWidget);
    },
  );

  testWidgets('a meetup whose window already started has check-in available '
      'immediately — no more isToday-means-always-open special case (ADR-016, '
      'every meetup has a real window now)', (tester) async {
    final service = ScriptedMeetupService(
      meetupDetail: _acceptedMeetup(),
      safetyState: const SafetyState(meetupId: 'meetup-1'),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [meetupServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(home: MeetupDetailPage(meetupId: 'meetup-1')),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('I UNDERSTAND'));
    await tester.pumpAndSettle();

    expect(find.text('CHECK IN'), findsOneWidget);
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
    });

    testWidgets(
      'shown for a pending request, and calls withdrawRequest with the '
      'entered note only on confirm',
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

        expect(find.text('WITHDRAW REQUEST'), findsOneWidget);

        await tester.tap(find.text('WITHDRAW REQUEST'));
        await tester.pumpAndSettle();
        expect(service.lastWithdrawRequestId, isNull); // dialog first

        await tester.enterText(
          find.byType(TextField),
          'Schedule conflict came up',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'WITHDRAW'));
        await tester.pumpAndSettle();

        expect(service.lastWithdrawRequestId, 'request-1');
        expect(service.lastWithdrawRequestNote, 'Schedule conflict came up');
        expect(find.text('Request withdrawn.'), findsOneWidget);

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

    testWidgets('the note is optional — confirming with an empty note '
        'still withdraws', (tester) async {
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

      await tester.tap(find.text('WITHDRAW REQUEST'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'WITHDRAW'));
      await tester.pumpAndSettle();

      expect(service.lastWithdrawRequestId, 'request-1');
      expect(service.lastWithdrawRequestNote, isNull);

      await tester.pump(const Duration(seconds: 3));
    });
  });

  group(
    'Feedback note popup (ADR-016) — optional, never blocks progression',
    () {
      testWidgets('Skip proceeds to submit feedback with no note', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(800, 2000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = ScriptedMeetupService(
          meetupDetail: _acceptedMeetup(),
          safetyState: const SafetyState(meetupId: 'meetup-1'),
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

        await tester.tap(find.text('IT HAPPENED'));
        await tester.pumpAndSettle();

        expect(find.text('Add a note (optional)'), findsOneWidget);

        await tester.tap(find.text('SKIP'));
        await tester.pumpAndSettle();

        expect(find.text('Thanks for the feedback.'), findsOneWidget);
        expect(service.lastSubmitFeedbackNotes, isNull);

        // Let the toast's hold timer + dismiss animation fully finish so
        // its OverlayEntry doesn't outlive this test's widget tree — the
        // ToastService's OverlayEntry is a static singleton shared across
        // every test in this isolate.
        await tester.pump(const Duration(seconds: 3));
      });

      testWidgets(
        'Save with text carries the note through to submitMeetupFeedback',
        (tester) async {
          tester.view.physicalSize = const Size(800, 2000);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          final service = ScriptedMeetupService(
            meetupDetail: _acceptedMeetup(),
            safetyState: const SafetyState(meetupId: 'meetup-1'),
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

          await tester.tap(find.text('IT HAPPENED'));
          await tester.pumpAndSettle();

          await tester.enterText(find.byType(TextField), 'Great coffee chat!');
          await tester.pump();
          // Closing the keyboard before popping the sheet avoids a focus/
          // text-input-driven relayout racing the sheet's dismiss animation
          // and the toast's Overlay insertion in the same frame.
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pump();
          await tester.tap(find.text('SAVE'));
          await tester.pumpAndSettle();

          expect(find.text('Thanks for the feedback.'), findsOneWidget);
          expect(service.lastSubmitFeedbackNotes, 'Great coffee chat!');

          // See the SKIP test's comment above for why this matters.
          await tester.pump(const Duration(seconds: 3));
        },
      );

      testWidgets('Save with only whitespace is treated the same as no note', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(800, 2000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = ScriptedMeetupService(
          meetupDetail: _acceptedMeetup(),
          safetyState: const SafetyState(meetupId: 'meetup-1'),
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

        await tester.tap(find.text('IT HAPPENED'));
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), '   ');
        await tester.pump();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        await tester.tap(find.text('SAVE'));
        await tester.pumpAndSettle();

        expect(service.lastSubmitFeedbackNotes, isNull);

        await tester.pump(const Duration(seconds: 3));
      });
    },
  );

  group('Decline (ADR-024 §4) — the safety checklist/check-in stage', () {
    testWidgets(
      'DECLINE opens a required-reason dialog, mirroring the cancel-reason '
      'dialog\'s shape — the confirm button stays disabled until non-empty',
      (tester) async {
        tester.view.physicalSize = const Size(800, 2000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = ScriptedMeetupService(
          meetupDetail: _acceptedMeetup(),
          safetyState: const SafetyState(meetupId: 'meetup-1'),
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

        await tester.tap(find.text('DECLINE'));
        await tester.pumpAndSettle();

        expect(find.text('DECLINE'), findsWidgets);
        final confirmButton = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'DECLINE').last,
        );
        expect(confirmButton.onPressed, isNull);

        await tester.enterText(find.byType(TextField), 'family emergency');
        await tester.pump();

        final enabledButton = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'DECLINE').last,
        );
        expect(enabledButton.onPressed, isNotNull);
      },
    );

    testWidgets(
      'submitting with a reason calls declineCheckIn and reflects the '
      'declined state — the screen no longer offers check-in',
      (tester) async {
        tester.view.physicalSize = const Size(800, 2000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = ScriptedMeetupService(
          meetupDetail: _acceptedMeetup(),
          safetyState: const SafetyState(meetupId: 'meetup-1'),
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

        await tester.tap(find.text('DECLINE'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'family emergency');
        await tester.pump();
        await tester.tap(find.widgetWithText(TextButton, 'DECLINE').last);
        await tester.pumpAndSettle();

        expect(service.lastDeclineCheckInMeetupId, 'meetup-1');
        expect(service.lastDeclineCheckInReason, 'family emergency');
        expect(find.text('Declined: family emergency'), findsOneWidget);
        // The terminal declined state replaces the CHECK IN/DECLINE
        // affordances — neither should still be offered.
        expect(find.text('CHECK IN'), findsNothing);
        expect(find.widgetWithText(SecondaryButton, 'DECLINE'), findsNothing);
      },
    );

    testWidgets('BACK dismisses the dialog without calling declineCheckIn', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final service = ScriptedMeetupService(
        meetupDetail: _acceptedMeetup(),
        safetyState: const SafetyState(meetupId: 'meetup-1'),
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

      await tester.tap(find.text('DECLINE'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'never mind');
      await tester.pump();
      await tester.tap(find.text('BACK'));
      await tester.pumpAndSettle();

      expect(service.lastDeclineCheckInMeetupId, isNull);
      // Still offering DECLINE — nothing was submitted.
      expect(find.widgetWithText(SecondaryButton, 'DECLINE'), findsOneWidget);
    });

    testWidgets(
      'a meetup already declined shows the terminal state directly, no '
      'CHECK IN or DECLINE offered',
      (tester) async {
        final service = ScriptedMeetupService(
          meetupDetail: _acceptedMeetup(),
          safetyState: SafetyState(
            meetupId: 'meetup-1',
            declinedAt: DateTime.now(),
            declineReason: 'double booked',
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

        expect(find.text('Declined: double booked'), findsOneWidget);
        expect(find.text('CHECK IN'), findsNothing);
        expect(find.widgetWithText(SecondaryButton, 'DECLINE'), findsNothing);
      },
    );
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
}
