import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/features/meetups/widgets/host_meetup_controls.dart';

import 'support/scripted_meetup_service.dart';

Meetup _meetup({
  DateTime? windowStart,
  int acceptedCount = 0,
  bool isHostedByMe = true,
  MeetupStatus status = MeetupStatus.open,
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
  acceptedCount: acceptedCount,
  status: status,
  createdAt: DateTime.now(),
  isHostedByMe: isHostedByMe,
);

Widget _wrap(Meetup meetup, {ValueChanged<Meetup>? onChanged}) {
  return ProviderScope(
    overrides: [
      meetupServiceProvider.overrideWithValue(
        ScriptedMeetupService(meetupDetail: meetup),
      ),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: HostMeetupControls(
          meetup: meetup,
          onChanged: onChanged ?? (_) {},
        ),
      ),
    ),
  );
}

void main() {
  group('HostMeetupControls visibility', () {
    testWidgets('renders nothing for a non-host', (tester) async {
      await tester.pumpWidget(_wrap(_meetup(isHostedByMe: false)));
      await tester.pumpAndSettle();

      expect(find.text('CLOSE MEETUP'), findsNothing);
      expect(find.text('CANCEL MEETUP'), findsNothing);
    });

    testWidgets('renders nothing once cancelled or completed', (tester) async {
      await tester.pumpWidget(_wrap(_meetup(status: MeetupStatus.cancelled)));
      await tester.pumpAndSettle();
      expect(find.text('CLOSE MEETUP'), findsNothing);
      expect(find.text('CANCEL MEETUP'), findsNothing);

      await tester.pumpWidget(_wrap(_meetup(status: MeetupStatus.completed)));
      await tester.pumpAndSettle();
      expect(find.text('CLOSE MEETUP'), findsNothing);
      expect(find.text('CANCEL MEETUP'), findsNothing);
    });

    testWidgets(
      'shows only CANCEL before the window starts (Close needs a started window)',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            _meetup(windowStart: DateTime.now().add(const Duration(hours: 1))),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('CANCEL MEETUP'), findsOneWidget);
        expect(find.text('CLOSE MEETUP'), findsNothing);
      },
    );

    testWidgets('shows both CLOSE and CANCEL once a participant is accepted — '
        'cancelling with accepted participants is allowed as of ADR-020 §3, '
        'not rejected server-side anymore', (tester) async {
      await tester.pumpWidget(_wrap(_meetup(acceptedCount: 1)));
      await tester.pumpAndSettle();

      expect(find.text('CLOSE MEETUP'), findsOneWidget);
      expect(find.text('CANCEL MEETUP'), findsOneWidget);
    });

    testWidgets('shows both, side by side, once the window has started and '
        'nobody has accepted yet', (tester) async {
      await tester.pumpWidget(_wrap(_meetup()));
      await tester.pumpAndSettle();

      expect(find.text('CLOSE MEETUP'), findsOneWidget);
      expect(find.text('CANCEL MEETUP'), findsOneWidget);
    });

    testWidgets('round-6 hardening: a null windowStart (ADR-028 redaction can '
        'genuinely produce one now) does not crash — CLOSE MEETUP just '
        "doesn't show, rather than force-unwrapping into an exception. "
        'Synthetic fixture: a real backend response would never pair '
        'isHostedByMe:true with a null windowStart post round-6\'s '
        'participation exception, but this getter checks explicitly rather '
        'than relying on that invariant holding forever.', (tester) async {
      final meetup = Meetup(
        id: 'meetup-1',
        hostUserId: 'host-1',
        hostFullName: 'Grace Hopper',
        hostTrustLevel: 3,
        intent: IntentType.coffee,
        locationLat: 6.9271,
        locationLng: 79.8612,
        locationLabel: 'Colombo Fort Cafe',
        capacity: 4,
        acceptedCount: 0,
        status: MeetupStatus.open,
        createdAt: DateTime.now(),
        isHostedByMe: true,
        // windowStart/windowEnd genuinely omitted (null).
      );

      await tester.pumpWidget(_wrap(meetup));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('CLOSE MEETUP'), findsNothing);
    });
  });

  group('HostMeetupControls overflow regression — the same RenderFlex class '
      'the PrimaryButton fix addressed, now checked against this new '
      'two-button-in-a-Row layout (ADR-016 addendum, 2026-08-20)', () {
    testWidgets(
      'both buttons side by side on an iPhone-SE-class (375px) device '
      'does not overflow',
      (tester) async {
        tester.view.physicalSize = const Size(375, 812);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(_wrap(_meetup()));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('CLOSE MEETUP'), findsOneWidget);
        expect(find.text('CANCEL MEETUP'), findsOneWidget);
      },
    );

    testWidgets('still no overflow on an even narrower (320px) device', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 690);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_wrap(_meetup()));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('HostMeetupControls actions actually call the service', () {
    testWidgets(
      'CLOSE MEETUP, confirmed, calls closeMeetup and reports the server\'s '
      'returned Meetup via onChanged',
      (tester) async {
        final meetup = _meetup();
        final closed = meetup.copyWith(
          status: MeetupStatus.completed,
          closedAt: DateTime.now(),
        );
        final service = ScriptedMeetupService(meetupDetail: meetup)
          ..closeMeetupResult = closed;
        Meetup? changedTo;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [meetupServiceProvider.overrideWithValue(service)],
            child: MaterialApp(
              home: Scaffold(
                body: HostMeetupControls(
                  meetup: meetup,
                  onChanged: (updated) => changedTo = updated,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('CLOSE MEETUP'));
        await tester.pumpAndSettle();
        expect(service.lastCloseMeetupId, isNull); // dialog first

        await tester.tap(find.text('CONFIRM'));
        await tester.pumpAndSettle();

        expect(service.lastCloseMeetupId, 'meetup-1');
        expect(changedTo?.status, MeetupStatus.completed);
      },
    );

    testWidgets(
      'CANCEL MEETUP, confirmed with a reason, calls cancelMeetup with that '
      'reason and reports a locally cancelled Meetup via onChanged (the '
      'server only returns success, no updated object)',
      (tester) async {
        final meetup = _meetup(
          windowStart: DateTime.now().add(const Duration(hours: 1)),
        );
        final service = ScriptedMeetupService(meetupDetail: meetup);
        Meetup? changedTo;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [meetupServiceProvider.overrideWithValue(service)],
            child: MaterialApp(
              home: Scaffold(
                body: HostMeetupControls(
                  meetup: meetup,
                  onChanged: (updated) => changedTo = updated,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('CANCEL MEETUP'));
        await tester.pumpAndSettle();
        expect(service.lastCancelMeetupId, isNull); // dialog first

        await tester.enterText(find.byType(TextField), 'Something came up');
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'CANCEL MEETUP'));
        await tester.pumpAndSettle();

        expect(service.lastCancelMeetupId, 'meetup-1');
        expect(service.lastCancelMeetupReason, 'Something came up');
        expect(changedTo?.status, MeetupStatus.cancelled);
        expect(changedTo?.cancelledAt, isNotNull);
        expect(changedTo?.cancellationReason, 'Something came up');
      },
    );

    testWidgets(
      'CANCEL MEETUP is blocked (the confirm button stays disabled) with an '
      'empty reason',
      (tester) async {
        final meetup = _meetup(
          windowStart: DateTime.now().add(const Duration(hours: 1)),
        );
        final service = ScriptedMeetupService(meetupDetail: meetup);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [meetupServiceProvider.overrideWithValue(service)],
            child: MaterialApp(
              home: Scaffold(
                body: HostMeetupControls(meetup: meetup, onChanged: (_) {}),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('CANCEL MEETUP'));
        await tester.pumpAndSettle();

        final confirmButton = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'CANCEL MEETUP'),
        );
        expect(confirmButton.onPressed, isNull);

        await tester.tap(find.widgetWithText(TextButton, 'CANCEL MEETUP'));
        await tester.pumpAndSettle();

        expect(service.lastCancelMeetupId, isNull);
      },
    );

    testWidgets('a server-side rejection surfaces via the standard error snack '
        'instead of silently updating', (tester) async {
      final meetup = _meetup(
        windowStart: DateTime.now().add(const Duration(hours: 1)),
      );
      final service = ScriptedMeetupService(meetupDetail: meetup)
        ..cancelMeetupError = const MeetupConflictException(
          'meetup: something went wrong',
        );
      Meetup? changedTo;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [meetupServiceProvider.overrideWithValue(service)],
          child: MaterialApp(
            home: Scaffold(
              body: HostMeetupControls(
                meetup: meetup,
                onChanged: (updated) => changedTo = updated,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('CANCEL MEETUP'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Something came up');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'CANCEL MEETUP'));
      await tester.pumpAndSettle();

      expect(find.text('meetup: something went wrong'), findsOneWidget);
      expect(changedTo, isNull);

      await tester.pump(const Duration(seconds: 3));
    });
  });
}
