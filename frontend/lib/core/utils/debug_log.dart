import 'package:flutter/foundation.dart';

/// [debugPrint], but only in debug builds (tracker #94, review finding
/// N-D10).
///
/// # WHY THE CALL SITES COULD NOT JUST BE LEFT ALONE
///
/// `debugPrint` reads as debug-only and is not: it survives release
/// builds and writes to the platform log, where on Android any app with
/// READ_LOGS — and anyone with the device on a USB cable — can read it.
/// Every call site in this app already knew that, which is why each one
/// carries a comment saying so and logs a type name instead of the error
/// object.
///
/// That discipline is exactly the problem. It works until somebody adds
/// the sixth call site without reading the other five, and the thing
/// they paste in is the raw exception — which for this app's auth and
/// location paths can carry an email address, a phone number or a
/// position. One gate removes the need to remember.
///
/// [kDebugMode] is a compile-time constant, so in a release build the
/// condition folds away and the call with it: the strings are not
/// assembled and do not appear in the binary.
void debugLog(String message) {
  if (kDebugMode) {
    debugPrint(message);
  }
}
