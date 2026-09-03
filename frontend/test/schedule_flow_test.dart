import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/meetups/schedule_flow.dart';
import 'package:professional_connections_platform/features/meetups/widgets/stadia_map_location_step.dart'
    show debugStadiaApiKeyOverride;

/// Resolves immediately to a fixed, already-Level-2 profile — the Intent
/// step gates on trust level, so every intent here needs to render
/// unlocked without going through the real session-restore path.
class _FakeAuthSessionNotifier extends AuthSessionNotifier {
  @override
  Future<AuthSessionState> build() async => const AuthSessionState(
    profile: UserProfile(id: 'user-1', fullName: 'Ada Lovelace', trustLevel: 2),
  );
}

Widget _appWith() {
  return ProviderScope(
    overrides: [authSessionProvider.overrideWith(_FakeAuthSessionNotifier.new)],
    child: const MaterialApp(home: ScheduleFlowPage()),
  );
}

/// Drives the Timing step's FROM or TO time picker: switches from the
/// default dial to keyboard input mode (far more reliable to drive in a
/// widget test than tapping dial coordinates), types the 24-hour hour and
/// minute, then confirms. No AM/PM period control to tap — the picker
/// forces `alwaysUse24HourFormat` (schedule_flow.dart's `_pickMeetupTime`),
/// so `hour` is 00–23 and Flutter's own `_TimePickerInput` never renders a
/// `_DayPeriodControl` in that mode.
Future<void> _enterTime(
  WidgetTester tester, {
  required String hour,
  required String minute,
}) async {
  await tester.tap(find.byIcon(Icons.keyboard_outlined));
  await tester.pumpAndSettle();

  final fields = find.byType(TextFormField);
  await tester.enterText(fields.at(0), hour);
  await tester.enterText(fields.at(1), minute);
  await tester.pumpAndSettle();

  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
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

  await tester.tap(find.text('FROM'));
  await tester.pumpAndSettle();
  await _enterTime(tester, hour: '15', minute: '00');

  await tester.tap(find.text('TO'));
  await tester.pumpAndSettle();
  await _enterTime(tester, hour: '17', minute: '00');

  await tester.tap(find.text('CONTINUE'));
  await tester.pumpAndSettle();

  expect(find.text('Where?'), findsOneWidget);
  await tester.enterText(
    find.widgetWithText(TextField, 'Search for a cafe, restaurant, or venue'),
    'Test Cafe',
  );
  await tester.pump();
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
        await tester.tap(find.text('FROM'));
        await tester.pumpAndSettle();
        await _enterTime(tester, hour: '15', minute: '00');
        await tester.tap(find.text('TO'));
        await tester.pumpAndSettle();
        await _enterTime(tester, hour: '17', minute: '00');
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
        await tester.pumpWidget(_appWith());
        await tester.pumpAndSettle();

        await tester.tap(find.text('COFFEE'));
        await tester.pumpAndSettle();

        expect(find.text('When should it happen?'), findsOneWidget);
      },
    );

    testWidgets('the date field defaults to today, not empty', (tester) async {
      await tester.pumpWidget(_appWith());
      await tester.pumpAndSettle();

      await tester.tap(find.text('COFFEE'));
      await tester.pumpAndSettle();

      final now = DateTime.now();
      final expected =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      expect(find.text(expected), findsOneWidget);
    });

    testWidgets('CONTINUE stays disabled until both FROM and TO are picked', (
      tester,
    ) async {
      await tester.pumpWidget(_appWith());
      await tester.pumpAndSettle();

      await tester.tap(find.text('COFFEE'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed !=
            null,
        isFalse,
      );

      await tester.tap(find.text('FROM'));
      await tester.pumpAndSettle();
      await _enterTime(tester, hour: '15', minute: '00');

      // Still disabled — TO not picked yet.
      expect(
        tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed !=
            null,
        isFalse,
      );

      await tester.tap(find.text('TO'));
      await tester.pumpAndSettle();
      await _enterTime(tester, hour: '17', minute: '00');

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
      await tester.pumpWidget(_appWith());
      await tester.pumpAndSettle();

      await tester.tap(find.text('COFFEE'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('FROM'));
      await tester.pumpAndSettle();
      await _enterTime(tester, hour: '00', minute: '00');

      // Midnight was accepted and stored — the placeholder is gone, and
      // it renders as 12:00 AM in this (ambient 12-hour) test locale,
      // the one time of day that formats that way, distinguishing it
      // from noon (12:00 PM).
      expect(find.text('Choose a start time'), findsNothing);
      expect(find.text('12:00 AM'), findsOneWidget);

      await tester.tap(find.text('TO'));
      await tester.pumpAndSettle();
      await _enterTime(tester, hour: '01', minute: '00');

      expect(
        tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed !=
            null,
        isTrue,
      );
    });

    testWidgets(
      'an end time before the start time shows an inline error and keeps '
      'CONTINUE disabled — the real check is server-side, this is fast '
      'client feedback',
      (tester) async {
        await tester.pumpWidget(_appWith());
        await tester.pumpAndSettle();

        await tester.tap(find.text('COFFEE'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('FROM'));
        await tester.pumpAndSettle();
        await _enterTime(tester, hour: '17', minute: '00');

        await tester.tap(find.text('TO'));
        await tester.pumpAndSettle();
        await _enterTime(tester, hour: '15', minute: '00');

        expect(
          find.text('End time must be after the start time.'),
          findsOneWidget,
        );
        expect(
          tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed !=
              null,
          isFalse,
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
