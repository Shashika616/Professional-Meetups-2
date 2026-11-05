import 'package:flutter/widgets.dart';

/// Whether the person asked the system for less motion.
///
/// Two signals, because the platforms report it differently: Android's
/// animation setting arrives through [MediaQuery], and iOS's Reduce Motion
/// through the accessibility features.
bool reducedMotion(BuildContext context) {
  final features =
      WidgetsBinding.instance.platformDispatcher.accessibilityFeatures;
  return (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ||
      features.reduceMotion;
}
