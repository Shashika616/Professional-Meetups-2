import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/meetups/schedule_flow.dart'
    show ScheduleFlowPage, debugScheduleFlowNowOverride;
import 'package:professional_connections_platform/features/meetups/widgets/stadia_map_location_step.dart'
    show debugStadiaApiKeyOverride;

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

Widget _appWith() {
  return ProviderScope(
    overrides: [authSessionProvider.overrideWith(_FakeAuthSessionNotifier.new)],
    child: const MaterialApp(home: ScheduleFlowPage()),
  );
}

/// Types a strict 24-hour time into the Timing step's FROM or TO field.
/// The fields are plain `TextField`s keyed `time24h-FROM` / `time24h-TO`
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
/// 3:00 PM–5:00 PM) → Location → lands on the Capacity step, since
/// capacity-stepper bounds are what most of these tests actually exercise.
/// One consistent flow now (ADR-016) — no more "Schedule Today" entry
/// choice to tap through first.
///
/// The Location step is [MapLocationStep] (real Stadia Maps integration) —
/// `debugStadiaApiKeyOverride` fakes a configured key so it renders its
/// real UI instead of the "not configured" state. Typing into the search
/// field starts a 400ms debounced autocomplete call against a real Stadia
/// endpoint; this helper deliberately taps CONTINUE and moves off the step
/// *before* that timer fires (a single `pump()`, never `pumpAndSettle()`,
/// in between) so `MapLocationStep.dispose()` cancels it — no real network
/// call ever happens in this test.
Future<void> _reachCapacityStep(WidgetTester tester) async {
  debugStadiaApiKeyOverride = 'test-key';
  addTearDown(() => debugStadiaApiKeyOverride = null);

  _pinClockToStartOfToday();
  await tester.pumpWidget(_appWith());
  await tester.pumpAndSettle();

  await tester.tap(find.text('COFFEE'));
  await tester.pumpAndSettle();

  expect(find.text('When should it happen?'), findsOneWidget);

  // Accept the default date (today) unchanged.
  await tester.tap(find.text('DATE'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();

  await _enterTime(tester, field: 'FROM', hhmm: '1500');

  await _enterTime(tester, field: 'TO', hhmm: '1700');

  await tester.ensureVisible(find.text('CONTINUE'));
  await tester.tap(find.text('CONTINUE'));
  await tester.pumpAndSettle();

  expect(find.text('Where?'), findsOneWidget);
  await tester.enterText(
    find.widgetWithText(TextField, 'Search for a cafe, restaurant, or venue'),
    'Test Cafe',
  );
  await tester.pump();
  await tester.ensureVisible(find.text('CONTINUE'));
  await tester.tap(find.text('CONTINUE'));
  await tester.pump();

  expect(find.text('How many people?'), findsOneWidget);
}

void main() {
  group('Schedule flow — location step, Stadia key not configured', () {
    testWidgets(
      'shows a clear "not configured" message instead of attempting to '
      'render the map',
      (tester) async {
        // No debugStadiaApiKeyOverride set — this is the real default
        // (AppConfig.stadiaMapsApiKey empty, no --dart-define passed).
        _pinClockToStartOfToday();
        await tester.pumpWidget(_appWith());
        await tester.pumpAndSettle();

        await tester.tap(find.text('COFFEE'));
        await tester.pumpAndSettle();

        // Through the Timing step first — every meetup requires a real
        // window now (ADR-016), there's no more "today" path that skips it.
        await tester.tap(find.text('DATE'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await _enterTime(tester, field: 'FROM', hhmm: '1500');
        await _enterTime(tester, field: 'TO', hhmm: '1700');
        await tester.ensureVisible(find.text('CONTINUE'));
        await tester.tap(find.text('CONTINUE'));
        await tester.pumpAndSettle();

        expect(find.textContaining('isn\'t configured'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        expect(find.text('CONTINUE'), findsNothing);
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

        await tester.tap(find.text('COFFEE'));
        await tester.pumpAndSettle();

        expect(find.text('When should it happen?'), findsOneWidget);
      },
    );

    testWidgets('the date field defaults to today, not empty', (tester) async {
      _pinClockToStartOfToday();
      await tester.pumpWidget(_appWith());
      await tester.pumpAndSettle();

      await tester.tap(find.text('COFFEE'));
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

      await tester.tap(find.text('COFFEE'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed !=
            null,
        isFalse,
      );

      await _enterTime(tester, field: 'FROM', hhmm: '1500');

      // Still disabled — TO not picked yet.
      expect(
        tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed !=
            null,
        isFalse,
      );

      await _enterTime(tester, field: 'TO', hhmm: '1700');

      expect(
        tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed !=
            null,
        isTrue,
      );
    });

    testWidgets('FROM supports entering 00:00 (midnight) — regression guard: a '
        '12-hour picker has no literal "00", only 1–12 + AM/PM, which is '
        'where users previously got stuck trying to schedule at midnight', (
      tester,
    ) async {
      _pinClockToStartOfToday();
      await tester.pumpWidget(_appWith());
      await tester.pumpAndSettle();

      await tester.tap(find.text('COFFEE'));
      await tester.pumpAndSettle();

      await _enterTime(tester, field: 'FROM', hhmm: '0000');

      // Midnight was accepted and reads back as strict 24-hour "00:00" —
      // never a locale-dependent "12:00 AM", which is the ambiguity this
      // entry mode exists to remove.
      expect(find.text('00:00'), findsOneWidget);

      await _enterTime(tester, field: 'TO', hhmm: '0100');

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

        await tester.tap(find.text('COFFEE'));
        await tester.pumpAndSettle();

        await _enterTime(tester, field: 'FROM', hhmm: '2200');
        await _enterTime(tester, field: 'TO', hhmm: '0100');

        expect(find.text('Ends the next day at 01:00.'), findsOneWidget);
        expect(
          tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed !=
              null,
          isTrue,
        );

        // And the window handed to the next step really does end tomorrow.
        await tester.ensureVisible(find.text('CONTINUE'));
        await tester.tap(find.text('CONTINUE'));
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

        await tester.tap(find.text('COFFEE'));
        await tester.pumpAndSettle();

        await _enterTime(tester, field: 'FROM', hhmm: '1500');
        await _enterTime(tester, field: 'TO', hhmm: '1500');

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

        await tester.tap(find.text('COFFEE'));
        await tester.pumpAndSettle();

        await _enterTime(tester, field: 'FROM', hhmm: '0900');
        await _enterTime(tester, field: 'TO', hhmm: '1100');

        expect(find.textContaining('has already passed today'), findsOneWidget);
        expect(
          tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed !=
              null,
          isFalse,
        );

        // Moving the start to the current minute clears it.
        await _enterTime(tester, field: 'FROM', hhmm: '1030');
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

        await tester.tap(find.text('COFFEE'));
        await tester.pumpAndSettle();

        // 25:00 — the "5" is refused after a leading "2", leaving "2".
        await _enterTime(tester, field: 'FROM', hhmm: '2500');
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('time24h-FROM')))
              .controller!
              .text,
          '2',
        );

        // 12:60 — the "6" is refused as a first minute digit, leaving "12"
        // (the colon only appears once a minute digit follows it).
        await _enterTime(tester, field: 'TO', hhmm: '1260');
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('time24h-TO')))
              .controller!
              .text,
          '12',
        );
      },
    );
  });

  group('Schedule flow — capacity-stepper bounds (backend CHECK 1..20)', () {
    testWidgets('decrement is disabled once capacity reaches the minimum (1)', (
      tester,
    ) async {
      await _reachCapacityStep(tester);

      // Draft starts at 2 — one tap down reaches the floor.
      await tester.tap(find.byIcon(Icons.remove_rounded));
      await tester.pumpAndSettle();
      expect(find.text('1'), findsOneWidget);

      final minusButton = tester.widget<GestureDetector>(
        find.ancestor(
          of: find.byIcon(Icons.remove_rounded),
          matching: find.byType(GestureDetector),
        ),
      );
      expect(minusButton.onTap, isNull);

      // Tapping again must not go below 1.
      await tester.tap(find.byIcon(Icons.remove_rounded));
      await tester.pumpAndSettle();
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets(
      'increment is disabled once capacity reaches the maximum (20)',
      (tester) async {
        await _reachCapacityStep(tester);

        // Draft starts at 2 — 18 taps reaches the cap.
        for (var i = 0; i < 18; i++) {
          await tester.tap(find.byIcon(Icons.add_rounded));
          await tester.pumpAndSettle();
        }
        expect(find.text('20'), findsOneWidget);

        final plusButton = tester.widget<GestureDetector>(
          find.ancestor(
            of: find.byIcon(Icons.add_rounded),
            matching: find.byType(GestureDetector),
          ),
        );
        expect(plusButton.onTap, isNull);

        // Tapping again must not go above 20.
        await tester.tap(find.byIcon(Icons.add_rounded));
        await tester.pumpAndSettle();
        expect(find.text('20'), findsOneWidget);
      },
    );
  });
}
