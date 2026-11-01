import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/analytics/event_names.g.dart';
import 'package:professional_connections_platform/core/widgets/app_back_button.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';

import 'package:professional_connections_platform/core/maps/map_provider.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:professional_connections_platform/core/models/credits.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/services/app_config_service.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/services/subscription_service.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/features/meetups/schedule_flow.dart'
    show ScheduleFlowPage, debugScheduleFlowNowOverride;

import 'support/analytics_harness.dart';
import 'support/app_icon_finder.dart';

import 'support/fake_credit_service.dart';
import 'support/scripted_meetup_service.dart';

/// Resolves immediately to a fixed, already-Level-2 profile — the Intent
/// step gates on trust level, so every intent here needs to render
/// unlocked without going through the real session-restore path.
class _FakeAuthSessionNotifier extends AuthSessionNotifier {
  @override
  Future<AuthSessionState> build() async => const AuthSessionState(
    // CHANGED (ADR-002 § 4): was trustLevel 2. This is the HOSTING flow, and
    // hosting an ordinary intent needs Level 3 now — at 2 the intent step
    // locks and the flow cannot advance past it, which is correct behaviour
    // and exactly what the gate test below asserts.
    profile: UserProfile(id: 'user-1', fullName: 'Ada Lovelace', trustLevel: 3),
  );
}

/// [service] answers the time step's schedule check (a free window by
/// default); the flow never reaches the network in these tests.
Widget _appWith({
  ScriptedMeetupService? service,
  FakeCreditService? credits,
  Widget home = const ScheduleFlowPage(),
}) {
  return ProviderScope(
    overrides: [
      authSessionProvider.overrideWith(_FakeAuthSessionNotifier.new),
      meetupServiceProvider.overrideWithValue(
        service ?? ScriptedMeetupService(),
      ),
      // Plan 29C: limits and prices come from billing. A fake that
      // answers at once keeps these tests on the flow itself.
      creditServiceProvider.overrideWithValue(credits ?? FakeCreditService()),
      subscriptionServiceProvider.overrideWithValue(_NoStore()),
      walletProvider.overrideWith((ref) async => Wallet.empty),
      appConfigProvider.overrideWith((ref) async => RemoteAppConfig.defaults),
    ],
    child: MaterialApp(home: home),
  );
}

/// Types a strict 24-hour time into the Timing step's FROM or TO field.
/// The fields are plain `TextField`s keyed `time24h-From` / `time24h-To`
/// (see `TimeField24h`), so this is a single `enterText` — no dialog, no
/// keyboard-mode toggle, no OK button. The formatter inserts the colon.
Future<void> _enterTime(
  WidgetTester tester, {
  required String field,
  required String hhmm,
}) async {
  await tester.enterText(find.byKey(ValueKey('time24h-$field')), hhmm);
  await tester.pumpAndSettle();
}

/// Pins the timing step's clock to 00:00 of the real calendar day, so that
/// any time typed below is "later today" no matter when the suite runs —
/// the step now refuses a start behind the clock, which would otherwise
/// make `15:00` fail every afternoon and `00:00` fail always. The real
/// date is kept (not a fixed one) because the DATE card and its test
/// compare against the actual today.
void _pinClockToStartOfToday() {
  final d = DateTime.now();
  debugScheduleFlowNowOverride = () => DateTime(d.year, d.month, d.day);
  addTearDown(() => debugScheduleFlowNowOverride = null);
}

/// Drives Intent → Timing (accepts the default date — today — then picks
/// 3:00 PM to 5:00 PM) → Location → lands on the Capacity step, since
/// capacity-stepper bounds are what most of these tests actually exercise.
/// One consistent flow now (ADR-016) — no more "Schedule Today" entry
/// choice to tap through first.
///
/// The Location step is [MapLocationStep]; on the default (OSM) provider
/// it needs no key, so it renders its real UI here. Typing into the search
/// field starts a debounced autocomplete call against a real geocoder;
/// this helper deliberately taps CONTINUE and moves off the step *before*
/// that timer fires (a single `pump()`, never `pumpAndSettle()`, in
/// between) so `MapLocationStep.dispose()` cancels it — no real network
/// call ever happens in this test.
Future<void> _reachCapacityStep(
  WidgetTester tester, {
  ScriptedMeetupService? service,
  FakeCreditService? credits,
}) async {
  _pinClockToStartOfToday();
  await tester.pumpWidget(_appWith(service: service, credits: credits));
  await tester.pumpAndSettle();

  await tester.tap(find.text('Coffee'));
  await tester.pumpAndSettle();

  expect(find.text('When should it happen?'), findsOneWidget);

  // Accept the default date (today) unchanged.
  await tester.tap(find.text('Date'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();

  await _enterTime(tester, field: 'From', hhmm: '1500');

  await _enterTime(tester, field: 'To', hhmm: '1700');

  await tester.ensureVisible(find.text('Continue'));
  await tester.tap(find.text('Continue'));
  await tester.pumpAndSettle();

  expect(find.text('Where?'), findsOneWidget);
  await tester.enterText(
    find.widgetWithText(TextField, 'Search for a cafe, restaurant, or venue'),
    'Test Cafe',
  );
  await tester.pump();
  // Typing opens the suggestions panel over the map, with a scrim that
  // deliberately covers the sheet: CONTINUE must not be reachable
  // through an open dropdown. Dismiss it the way a person does before
  // reaching the sheet underneath.
  await tester.tapAt(const Offset(200, 400));
  await tester.pump();
  await tester.ensureVisible(find.text('Continue'));
  await tester.tap(find.text('Continue'));
  await tester.pump();

  expect(find.text('How many people?'), findsOneWidget);
}

void main() {
  // Plan 29E: the schedule-a-meetup funnel.
  group('Schedule flow — funnel analytics', () {
    const flow = AnalyticsFlow.scheduleMeetup;
    const intent = 'intent', timing = 'timing', location = 'location';
    const capacity = 'capacity', review = 'review';

    Meetup created() => Meetup(
      id: 'm-1',
      hostUserId: 'user-1',
      hostFullName: 'Ada Lovelace',
      hostTrustLevel: 3,
      intent: IntentType.coffee,
      windowStart: DateTime.now().add(const Duration(hours: 3)),
      windowEnd: DateTime.now().add(const Duration(hours: 4)),
      locationLat: 6.9,
      locationLng: 79.8,
      locationLabel: 'Test Cafe',
      capacity: 2,
      acceptedCount: 0,
      status: MeetupStatus.open,
      createdAt: DateTime.now(),
      isHostedByMe: true,
    );

    testWidgets('every step in order, then completed', (tester) async {
      final analytics = await installTestAnalytics();
      tester.view.physicalSize = const Size(1080, 3000);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      final service = ScriptedMeetupService(meetupDetail: created())
        ..createMeetupScript.add(created());
      final credits = FakeCreditService()
        ..quoteScript = [quoteOf(12, available: 60)];
      await _reachCapacityStep(tester, service: service, credits: credits);
      await tester.ensureVisible(find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('reviewConfirm')));
      await tester.tap(find.byKey(const Key('reviewConfirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(flowEvents(analytics, flow), [
        'flow_started',
        'flow_step_viewed:$intent',
        'flow_step_completed:$intent',
        'flow_step_viewed:$timing',
        'flow_step_completed:$timing',
        'flow_step_viewed:$location',
        'flow_step_completed:$location',
        'flow_step_viewed:$capacity',
        'flow_step_completed:$capacity',
        'flow_step_viewed:$review',
        'flow_step_completed:$review',
        'flow_completed:$review',
      ]);
      // Leaving the page after success is not an abandonment.
      await tester.pumpWidget(const SizedBox());
      expect(
        flowEvents(
          analytics,
          flow,
        ).where((e) => e.startsWith('flow_abandoned')),
        isEmpty,
      );
    });

    testWidgets('backing out is an abandonment at the step it left from', (
      tester,
    ) async {
      final analytics = await installTestAnalytics();
      await tester.pumpWidget(
        _appWith(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ScheduleFlowPage(),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Coffee'));
      await tester.pumpAndSettle();
      // Back to the intent step, then out of the flow.
      await tester.tap(find.byType(AppBackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(AppBackButton));
      await tester.pumpAndSettle();
      expect(find.byType(ScheduleFlowPage), findsNothing);

      final events = flowEvents(analytics, flow);
      expect(events, [
        'flow_started',
        'flow_step_viewed:$intent',
        'flow_step_completed:$intent',
        'flow_step_viewed:$timing',
        'flow_step_viewed:$intent',
        'flow_abandoned:$intent',
      ]);
      final abandoned = queued(
        analytics,
      ).lastWhere((e) => e['event_name'] == AnalyticsEvent.flowAbandoned);
      expect(
        (abandoned['attributes'] as Map)[AnalyticsAttribute.reason],
        AnalyticsValue.flowAbandonedReasonBack,
      );
    });

    testWidgets('30 minutes in the background abandons it where it stood', (
      tester,
    ) async {
      final analytics = await installTestAnalytics();
      _pinClockToStartOfToday();
      await tester.pumpWidget(_appWith());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Coffee'));
      await tester.pumpAndSettle();

      analytics.lifecycleChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(minutes: 31));
      analytics.lifecycleChanged(AppLifecycleState.resumed);

      final abandoned = queued(
        analytics,
      ).lastWhere((e) => e['event_name'] == AnalyticsEvent.flowAbandoned);
      expect(abandoned['flow_step'], timing);
      expect(
        (abandoned['attributes'] as Map)[AnalyticsAttribute.reason],
        AnalyticsValue.flowAbandonedReasonBackgrounded,
      );
      // The page closing later does not abandon it a second time.
      await tester.pumpWidget(const SizedBox());
      expect(
        flowEvents(
          analytics,
          flow,
        ).where((e) => e.startsWith('flow_abandoned')),
        hasLength(1),
      );
    });
  });

  group('Schedule flow — location step, Stadia selected without a key', () {
    testWidgets(
      'shows a clear "not configured" message instead of attempting to '
      'render the map',
      (tester) async {
        // The one configuration that cannot draw a map: the Stadia
        // provider with no key. The default (OSM) needs none.
        MapConfig.debugProviderOverride = MapProvider.stadia;
        addTearDown(() => MapConfig.debugProviderOverride = null);
        _pinClockToStartOfToday();
        await tester.pumpWidget(_appWith());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Coffee'));
        await tester.pumpAndSettle();

        // Through the Timing step first — every meetup requires a real
        // window now (ADR-016), there's no more "today" path that skips it.
        await tester.tap(find.text('Date'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await _enterTime(tester, field: 'From', hhmm: '1500');
        await _enterTime(tester, field: 'To', hhmm: '1700');
        await tester.ensureVisible(find.text('Continue'));
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        expect(find.textContaining('isn\'t configured'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        expect(find.text('Continue'), findsNothing);
      },
    );
  });

  group('Schedule flow — timing step (ADR-016: one consistent flow)', () {
    testWidgets(
      'the Timing step is always shown — no more "Schedule Today" skip',
      (tester) async {
        _pinClockToStartOfToday();
        await tester.pumpWidget(_appWith());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Coffee'));
        await tester.pumpAndSettle();

        expect(find.text('When should it happen?'), findsOneWidget);
      },
    );

    testWidgets('the date field defaults to today, not empty', (tester) async {
      _pinClockToStartOfToday();
      await tester.pumpWidget(_appWith());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Coffee'));
      await tester.pumpAndSettle();

      // Human-readable now ("Today · Fri 11 Sep"), not the ISO form the
      // card used to show — but still today, which is the point.
      expect(find.textContaining('Today · '), findsOneWidget);
    });

    testWidgets('CONTINUE stays disabled until both FROM and TO are picked', (
      tester,
    ) async {
      _pinClockToStartOfToday();
      await tester.pumpWidget(_appWith());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Coffee'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed !=
            null,
        isFalse,
      );

      await _enterTime(tester, field: 'From', hhmm: '1500');

      // Still disabled — TO not picked yet.
      expect(
        tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed !=
            null,
        isFalse,
      );

      await _enterTime(tester, field: 'To', hhmm: '1700');

      expect(
        tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed !=
            null,
        isTrue,
      );
    });

    testWidgets('FROM supports entering 00:00 (midnight) — regression guard: a '
        '12-hour picker has no literal "00", only 1 - 12 + AM/PM, which is '
        'where users previously got stuck trying to schedule at midnight', (
      tester,
    ) async {
      _pinClockToStartOfToday();
      await tester.pumpWidget(_appWith());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Coffee'));
      await tester.pumpAndSettle();

      await _enterTime(tester, field: 'From', hhmm: '0000');

      // Midnight was accepted and reads back as strict 24-hour "00:00" —
      // never a locale-dependent "12:00 AM", which is the ambiguity this
      // entry mode exists to remove.
      expect(find.text('00:00'), findsOneWidget);

      await _enterTime(tester, field: 'To', hhmm: '0100');

      expect(
        tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed !=
            null,
        isTrue,
      );
    });

    testWidgets(
      'an end time at or before the start on the clock means the NEXT day '
      '— 22:00 to 01:00 is a valid window ending tomorrow, and the step '
      'says so out loud',
      (tester) async {
        _pinClockToStartOfToday();
        await tester.pumpWidget(_appWith());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Coffee'));
        await tester.pumpAndSettle();

        await _enterTime(tester, field: 'From', hhmm: '2200');
        await _enterTime(tester, field: 'To', hhmm: '0100');

        expect(find.text('Ends the next day at 01:00.'), findsOneWidget);
        expect(
          tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed !=
              null,
          isTrue,
        );

        // And the window handed to the next step really does end tomorrow.
        await tester.ensureVisible(find.text('Continue'));
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        expect(find.text('Where?'), findsOneWidget);
      },
    );

    testWidgets(
      'the same minute for FROM and TO is refused — it would otherwise '
      'roll over into a 24-hour meetup',
      (tester) async {
        _pinClockToStartOfToday();
        await tester.pumpWidget(_appWith());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Coffee'));
        await tester.pumpAndSettle();

        await _enterTime(tester, field: 'From', hhmm: '1500');
        await _enterTime(tester, field: 'To', hhmm: '1500');

        expect(
          find.text('End time must be different from the start time.'),
          findsOneWidget,
        );
        expect(
          tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed !=
              null,
          isFalse,
        );
      },
    );

    testWidgets(
      'a start time already behind the clock today is refused HERE, not '
      'three steps later by the backend',
      (tester) async {
        // Pin the clock to 10:30 today: 09:00 is gone, 10:30 is not.
        final d = DateTime.now();
        debugScheduleFlowNowOverride = () =>
            DateTime(d.year, d.month, d.day, 10, 30, 45);
        addTearDown(() => debugScheduleFlowNowOverride = null);
        await tester.pumpWidget(_appWith());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Coffee'));
        await tester.pumpAndSettle();

        await _enterTime(tester, field: 'From', hhmm: '0900');
        await _enterTime(tester, field: 'To', hhmm: '1100');

        expect(find.textContaining('has already passed today'), findsOneWidget);
        expect(
          tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed !=
              null,
          isFalse,
        );

        // Moving the start to the current minute clears it.
        await _enterTime(tester, field: 'From', hhmm: '1030');
        expect(find.textContaining('has already passed today'), findsNothing);
        expect(
          tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed !=
              null,
          isTrue,
        );
      },
    );

    testWidgets(
      'the field will not accept digits that cannot form a 24-hour time',
      (tester) async {
        _pinClockToStartOfToday();
        await tester.pumpWidget(_appWith());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Coffee'));
        await tester.pumpAndSettle();

        // 25:00 — the "5" is refused after a leading "2", leaving "2".
        await _enterTime(tester, field: 'From', hhmm: '2500');
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('time24h-From')))
              .controller!
              .text,
          '2',
        );

        // 12:60 — the "6" is refused as a first minute digit, leaving "12"
        // (the colon only appears once a minute digit follows it).
        await _enterTime(tester, field: 'To', hhmm: '1260');
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('time24h-To')))
              .controller!
              .text,
          '12',
        );
      },
    );
  });

  group('Schedule flow — the schedule check at the time step (ADR-005)', () {
    Meetup busy() => Meetup(
      id: 'busy-1',
      hostUserId: 'user-1',
      hostFullName: 'Ada Lovelace',
      hostTrustLevel: 3,
      intent: IntentType.networking,
      windowStart: DateTime.now().add(const Duration(hours: 2)),
      windowEnd: DateTime.now().add(const Duration(hours: 3)),
      locationLabel: 'Barefoot Cafe',
      capacity: 3,
      acceptedCount: 0,
      status: MeetupStatus.open,
      createdAt: DateTime.now(),
      isHostedByMe: true,
    );

    Future<void> pickTimes(WidgetTester tester) async {
      _pinClockToStartOfToday();
      await tester.tap(find.text('Coffee'));
      await tester.pumpAndSettle();
      await _enterTime(tester, field: 'From', hhmm: '1500');
      await _enterTime(tester, field: 'To', hhmm: '1700');
      await tester.ensureVisible(find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
    }

    testWidgets('CONTINUE asks the server about the window and moves on '
        'when it is free', (tester) async {
      final service = ScriptedMeetupService();
      await tester.pumpWidget(_appWith(service: service));
      await tester.pumpAndSettle();
      await pickTimes(tester);

      expect(service.findScheduleConflictCallCount, 1);
      expect(service.lastScheduleCheckStart!.hour, 15);
      expect(service.lastScheduleCheckEnd!.hour, 17);
      expect(find.text('Where?'), findsOneWidget);
    });

    testWidgets('a busy window shows the conflict sheet and stays on the '
        'time step, so another time can be picked', (tester) async {
      final service = ScriptedMeetupService()..scheduleConflict = busy();
      await tester.pumpWidget(_appWith(service: service));
      await tester.pumpAndSettle();
      await pickTimes(tester);

      expect(find.text('One meetup at a time'), findsOneWidget);
      expect(
        find.text("You're already hosting a meetup at that time"),
        findsOneWidget,
      );
      await tester.tap(find.text("I'll wait"));
      await tester.pumpAndSettle();
      expect(find.text('When should it happen?'), findsOneWidget);
      expect(find.text('Where?'), findsNothing);
    });

    testWidgets('a failed check does not stop the flow: the create call '
        'still enforces the rule', (tester) async {
      final service = ScriptedMeetupService()
        ..findScheduleConflictError = Exception('offline');
      await tester.pumpWidget(_appWith(service: service));
      await tester.pumpAndSettle();
      await pickTimes(tester);

      expect(find.text('Where?'), findsOneWidget);
    });
  });

  group('Schedule flow — capacity-stepper bounds (backend CHECK 1..20)', () {
    testWidgets('decrement is disabled once capacity reaches the minimum (1)', (
      tester,
    ) async {
      await _reachCapacityStep(tester);

      // Draft starts at 2 — one tap down reaches the floor.
      await tester.tap(findAppIcon(AppIcons.minus));
      await tester.pumpAndSettle();
      expect(find.text('1'), findsOneWidget);

      final minusButton = tester.widget<GestureDetector>(
        find.ancestor(
          of: findAppIcon(AppIcons.minus),
          matching: find.byType(GestureDetector),
        ),
      );
      expect(minusButton.onTap, isNull);

      // Tapping again must not go below 1.
      await tester.tap(findAppIcon(AppIcons.minus));
      await tester.pumpAndSettle();
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets(
      'increment is disabled once capacity reaches the maximum (20)',
      (tester) async {
        await _reachCapacityStep(tester);

        // Draft starts at 2 — 18 taps reaches the cap.
        for (var i = 0; i < 18; i++) {
          await tester.tap(findAppIcon(AppIcons.plus));
          await tester.pumpAndSettle();
        }
        expect(find.text('20'), findsOneWidget);

        final plusButton = tester.widget<GestureDetector>(
          find.ancestor(
            of: findAppIcon(AppIcons.plus),
            matching: find.byType(GestureDetector),
          ),
        );
        expect(plusButton.onTap, isNull);

        // Tapping again must not go above 20.
        await tester.tap(findAppIcon(AppIcons.plus));
        await tester.pumpAndSettle();
        expect(find.text('20'), findsOneWidget);
      },
    );
  });

  group('Schedule flow — credits (plan 29C)', () {
    Meetup created() => Meetup(
      id: 'm-1',
      hostUserId: 'user-1',
      hostFullName: 'Ada Lovelace',
      hostTrustLevel: 3,
      intent: IntentType.coffee,
      windowStart: DateTime.now().add(const Duration(hours: 3)),
      windowEnd: DateTime.now().add(const Duration(hours: 4)),
      locationLat: 6.9,
      locationLng: 79.8,
      locationLabel: 'Test Cafe',
      capacity: 2,
      acceptedCount: 0,
      status: MeetupStatus.open,
      createdAt: DateTime.now(),
      isHostedByMe: true,
    );

    Future<void> reachReview(
      WidgetTester tester,
      ScriptedMeetupService service,
      FakeCreditService credits,
    ) async {
      tester.view.physicalSize = const Size(1080, 3000);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await _reachCapacityStep(tester, service: service, credits: credits);
      await tester.ensureVisible(find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Review & confirm'), findsOneWidget);
    }

    Finder costRow() => find.byKey(const Key('reviewCost'));
    PrimaryButton confirm(WidgetTester tester) =>
        tester.widget<PrimaryButton>(find.byKey(const Key('reviewConfirm')));

    Future<void> tapConfirm(WidgetTester tester) async {
      await tester.ensureVisible(find.byKey(const Key('reviewConfirm')));
      await tester.tap(find.byKey(const Key('reviewConfirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets(
      'the review step shows the server\'s cost and the balance, and creating carries it',
      (tester) async {
        final service = ScriptedMeetupService(meetupDetail: created())
          ..createMeetupScript.add(created());
        final credits = FakeCreditService()
          ..quoteScript = [quoteOf(12, available: 60)];
        await reachReview(tester, service, credits);

        expect(
          find.descendant(of: costRow(), matching: find.text('12 credits')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: costRow(),
            matching: find.text('Your balance: 60 credits'),
          ),
          findsOneWidget,
        );
        expect(credits.quoteCalls.single.capacity, 2);
        expect(confirm(tester).label, 'Confirm & schedule');

        await tapConfirm(tester);
        final charge = service.createMeetupCharges.single!;
        expect(charge.expectedCost, 12);
        expect(charge.priceVersion, 1);
        expect(charge.idempotencyKey, isNotEmpty);
      },
    );

    testWidgets('a plan-covered meetup says so instead of a cost', (
      tester,
    ) async {
      final credits = FakeCreditService()
        ..quoteScript = [quoteOf(0, available: 0, plan: true)];
      await reachReview(tester, ScriptedMeetupService(), credits);
      expect(
        find.descendant(
          of: costRow(),
          matching: find.text('Included in your plan'),
        ),
        findsOneWidget,
      );
      expect(confirm(tester).label, 'Confirm & schedule');
    });

    testWidgets(
      'not enough credits: BUY CREDITS, then a new quote, then it schedules',
      (tester) async {
        final service = ScriptedMeetupService(meetupDetail: created())
          ..createMeetupScript.add(created());
        final credits = FakeCreditService()
          ..catalogResult = Catalog.empty
          ..quoteScript = [
            quoteOf(30, available: 10),
            quoteOf(30, available: 80),
          ];
        await reachReview(tester, service, credits);

        expect(confirm(tester).label, 'Buy credits');
        await tester.ensureVisible(find.byKey(const Key('reviewConfirm')));
        await tester.tap(find.byKey(const Key('reviewConfirm')));
        await tester.pumpAndSettle();
        expect(
          find.text('Buy credits'),
          findsWidgets,
          reason: 'the buy-credits page is open',
        );
        expect(find.byKey(const Key('buyCreditsEmpty')), findsOneWidget);

        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(credits.quoteCalls, hasLength(2), reason: 're-quoted on return');
        expect(
          find.descendant(
            of: costRow(),
            matching: find.text('Your balance: 80 credits'),
          ),
          findsOneWidget,
        );
        expect(confirm(tester).label, 'Confirm & schedule');

        await tapConfirm(tester);
        expect(service.createMeetupCharges, hasLength(1));
        expect(service.createMeetupCharges.single!.expectedCost, 30);
      },
    );

    testWidgets(
      'price_changed shows the new cost and asks again, as a new submission',
      (tester) async {
        final service = ScriptedMeetupService(meetupDetail: created())
          ..createMeetupScript.addAll([
            const MeetupPriceChangedException(
              'The price changed.',
              cost: 14,
              priceVersion: 2,
            ),
            created(),
          ]);
        final credits = FakeCreditService()
          ..quoteScript = [quoteOf(10), quoteOf(14, version: 2)];
        await reachReview(tester, service, credits);

        await tapConfirm(tester);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('reviewCostNotice')), findsOneWidget);
        expect(
          find.textContaining('The price is now 14 credits'),
          findsOneWidget,
        );
        expect(
          find.descendant(of: costRow(), matching: find.text('14 credits')),
          findsOneWidget,
        );

        await tapConfirm(tester);
        expect(service.createMeetupCharges, hasLength(2));
        final first = service.createMeetupCharges[0]!,
            second = service.createMeetupCharges[1]!;
        expect(second.expectedCost, 14);
        expect(second.priceVersion, 2);
        expect(second.idempotencyKey, isNot(first.idempotencyKey));
      },
    );

    testWidgets('update_required shows the server\'s message', (tester) async {
      final service = ScriptedMeetupService()
        ..createMeetupScript.add(
          const MeetupUpdateRequiredException(
            'Update TieHere to host a meetup.',
          ),
        );
      await reachReview(tester, service, FakeCreditService());
      await tapConfirm(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Update TieHere to host a meetup.'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets(
      'a retry after a dropped connection reuses the same idempotency key',
      (tester) async {
        final service = ScriptedMeetupService(meetupDetail: created())
          ..createMeetupScript.addAll([
            const MeetupOfflineException(),
            created(),
          ]);
        await reachReview(tester, service, FakeCreditService());
        await tapConfirm(tester);
        await tester.pumpAndSettle(const Duration(seconds: 5));
        await tapConfirm(tester);
        expect(service.createMeetupCharges, hasLength(2));
        expect(
          service.createMeetupCharges[1]!.idempotencyKey,
          service.createMeetupCharges[0]!.idempotencyKey,
        );
      },
    );

    testWidgets('a plan raises the stepper to its own limit', (tester) async {
      final credits = FakeCreditService()
        ..entitlementsResult = const Entitlements(
          limits: CreationLimits(maxCapacity: 30, maxAdvanceDays: 30),
          planCode: 'pro',
        );
      await _reachCapacityStep(tester, credits: credits);
      for (var i = 0; i < 28; i++) {
        await tester.tap(findAppIcon(AppIcons.plus));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.text('30'), findsOneWidget);
      final plus = tester.widget<GestureDetector>(
        find.ancestor(
          of: findAppIcon(AppIcons.plus),
          matching: find.byType(GestureDetector),
        ),
      );
      expect(plus.onTap, isNull);
    });

    testWidgets(
      'the date picker reaches as far as the entitlement, 14 days by default',
      (tester) async {
        for (final (credits, days) in [
          (FakeCreditService(), 14),
          (
            FakeCreditService()
              ..entitlementsResult = const Entitlements(
                limits: CreationLimits(maxCapacity: 30, maxAdvanceDays: 30),
              ),
            30,
          ),
          (FakeCreditService()..entitlementsError = Exception('down'), 14),
        ]) {
          _pinClockToStartOfToday();
          await tester.pumpWidget(_appWith(credits: credits));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Coffee'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Date'));
          await tester.pumpAndSettle();
          final picker = tester.widget<DatePickerDialog>(
            find.byType(DatePickerDialog),
          );
          expect(picker.lastDate.difference(picker.firstDate).inDays, days);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox());
        }
      },
    );
  });
}

/// No store at all: the buy-credits page renders its empty state.
class _NoStore implements SubscriptionService {
  @override
  Future<List<ProductDetails>> availableProducts(
    List<String> productIds,
  ) async => const [];

  @override
  Future<SubscriptionStatus> currentStatus() async => const SubscriptionStatus(
    tier: SubscriptionTier.free,
    status: SubscriptionLifecycleStatus.none,
  );

  @override
  Future<void> restorePurchases() async {}

  @override
  Future<SubscriptionStatus> verifyPurchase({
    required String platform,
    required String receiptOrToken,
    required String productId,
  }) async => throw UnimplementedError();
}
