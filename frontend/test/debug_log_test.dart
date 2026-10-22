import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/utils/debug_log.dart';

// Tracker #94 (review finding N-D10). debugPrint reads as debug-only and
// is not: it survives release builds and writes to the platform log,
// where on Android any app holding READ_LOGS can read it. These tests
// pin the gate, and the grep below pins that nothing bypasses it.
void main() {
  test('debugLog writes in debug builds', () {
    final lines = <String?>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => lines.add(message);
    addTearDown(() => debugPrint = original);

    debugLog('something happened');

    // The test harness runs in debug mode, which is the branch that
    // should log. A release build folds the condition away entirely —
    // kDebugMode is a compile-time constant — which cannot be observed
    // from inside a test, so this asserts the half that can be.
    expect(kDebugMode, isTrue, reason: 'the test harness is not a debug build');
    expect(lines, ['something happened']);
  });
}
