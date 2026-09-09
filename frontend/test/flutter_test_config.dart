import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:professional_connections_platform/core/widgets/ambient_animation.dart';

/// Runs once before every test in this directory — Flutter's own
/// convention for this exact filename/signature, not a hand-rolled hook.
///
/// Without this, any test that renders a widget reading `themeModeProvider`
/// (Slice G — that's `ProfilePage`, and the app root itself) hangs
/// indefinitely: `ThemeModeNotifier` calls `SharedPreferences.getInstance()`,
/// which has no real platform channel to answer under `flutter test` and,
/// unlike `flutter_secure_storage`'s fast-failing `MissingPluginException`,
/// just never resolves — that hung the whole run at the test framework's
/// 10-minute timeout before this fix, not just `theme_toggle_test.dart`'s
/// own tests. `setMockInitialValues` wires an in-memory store instead, so
/// every test starts with no persisted theme preference (consistent with
/// `ThemeModeNotifier`'s own "default dark" behavior on a genuinely fresh
/// install).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  SharedPreferences.setMockInitialValues({});

  // Freeze every ambient (forever-repeating, input-free) animation for the
  // whole suite: the loading shimmer, the review card's attention pulse.
  //
  // WHY: a repeating AnimationController schedules frames forever and
  // `pumpAndSettle` waits for frames to stop, so any test that settles while
  // one is on screen hangs until it times out. Eight tests hung on the
  // shimmer; two more on the pulse.
  //
  // NOT done via the OS "reduce motion" accessibility flag, which was the
  // first attempt: setting that makes Flutter scale every other
  // AnimationController by 0.05 as well, and a pull-to-refresh test started
  // failing because its gesture timings moved underneath it. This flag
  // affects ambient animations and nothing else.
  //
  // The ANIMATED path is covered deliberately in `skeleton_loader_test.dart`,
  // which turns this back off for its own tests, so neither branch is left
  // untested.
  debugDisableAmbientAnimations = true;

  await testMain();
}
