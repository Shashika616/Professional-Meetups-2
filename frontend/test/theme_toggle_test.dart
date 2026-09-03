import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/main.dart';

import 'support/fake_meetup_service.dart';

/// Resolves immediately to a fixed (logged-out) [AuthSessionState] instead
/// of reading secure storage — without this, [SplashScreen]'s
/// `authSessionProvider.future` await hangs on the real
/// `flutter_secure_storage` platform channel (no test binding registered
/// under `flutter test`), which doesn't fail fast, it just never resolves,
/// timing the whole test out. Same fake `home_page_test.dart` already uses
/// for the same reason.
class _FakeAuthSessionNotifier extends AuthSessionNotifier {
  _FakeAuthSessionNotifier(this._state);

  final AuthSessionState _state;

  @override
  Future<AuthSessionState> build() async => _state;
}

/// [AppPalette]'s mode is a bare static field (Slice G's own doc comment
/// on it explains why — every existing `AppPalette.someColor` call site
/// reads it directly, not through Riverpod) — it isn't reset between
/// tests by anything Riverpod-owned, so a toggle left over from one test
/// would otherwise leak into the next one in this file (or, worse, into
/// an unrelated test file run in the same isolate).
void main() {
  // flutter_test_config.dart mocks SharedPreferences once for the whole
  // run (so any test anywhere that happens to render a themeModeProvider
  // reader doesn't hang) — but that in-memory store persists across every
  // test in this file since it's only reset once, not per test. This
  // file's own toggle test genuinely writes a persisted value, so it must
  // reset per test or a later test (the "default is dark" one) would see
  // an earlier test's leftover 'light' write.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    AppPalette.setMode(AppThemeMode.dark);
  });

  testWidgets(
    'toggling themeModeProvider actually flips a live, already-rendered '
    'widget\'s color — the point being to prove the keyed-MaterialApp '
    'rebuild mechanism really propagates the change, not just that the '
    'provider\'s own value changed',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          authSessionProvider.overrideWith(
            () => _FakeAuthSessionNotifier(const AuthSessionState()),
          ),
          meetupServiceProvider.overrideWithValue(ImmediateMeetupService()),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const ProfessionalConnectionsApp(),
        ),
      );
      await tester.pump();

      Color sampledColor() {
        final container = tester.widget<Container>(
          find.byKey(const ValueKey('splash-gradient-container')),
        );
        final decoration = container.decoration! as BoxDecoration;
        return (decoration.gradient! as LinearGradient).colors.first;
      }

      // Baseline: default mode is dark (no toggle yet), and the live
      // widget's rendered color matches the dark value.
      expect(container.read(themeModeProvider), AppThemeMode.dark);
      final beforeColor = sampledColor();
      expect(beforeColor, AppPalette.onyx);

      await container.read(themeModeProvider.notifier).toggle();
      await tester.pump();

      final afterColor = sampledColor();
      // Not just "changed to something" — changed to exactly the current
      // (now light-mode) AppPalette.onyx value, proving the rebuilt widget
      // re-read the getter rather than keeping its old painted color.
      expect(afterColor, isNot(beforeColor));
      expect(afterColor, AppPalette.onyx);

      // Flushes SplashScreen's pending 2-second navigation timer so it
      // isn't still pending when this test ends (same pattern this test
      // suite already uses for the toast overlay's own hold timer).
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets(
    'default theme mode on a fresh install is dark, not system-derived — '
    'no shared_preferences value has been written yet, so build() must not '
    'fall back to Brightness/MediaQuery instead',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(themeModeProvider), AppThemeMode.dark);

      // Pump once so ThemeModeNotifier.build()'s fire-and-forget prefs
      // read (which would only ever flip this to light if a previous run
      // had persisted 'light' — nothing has, in a fresh ProviderContainer)
      // has a chance to run and confirms it does NOT change the outcome.
      await tester.pump();
      expect(container.read(themeModeProvider), AppThemeMode.dark);
    },
  );
}
