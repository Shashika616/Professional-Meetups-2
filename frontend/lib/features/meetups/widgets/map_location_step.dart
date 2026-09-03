import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:professional_connections_platform/features/meetups/widgets/ios_map_location_step.dart';
import 'package:professional_connections_platform/features/meetups/widgets/stadia_map_location_step.dart';

/// The Schedule flow's location step (ADR-013 §4's third correction;
/// frontend/meetup-scheduling-PLAN.md's 2026-08-18 platform-split
/// addendum) — same name and the same `onSubmit(lat, lng, label)` contract
/// as before, but now a thin platform switch rather than a single
/// implementation:
///
/// - **iOS**: [IosMapLocationStep] — Apple MapKit, no API key, settled as
///   the iOS decision (not provisional).
/// - **Everything else (Android, and a reasonable fallback for any other
///   target)**: [StadiaMapLocationStep] — the existing Stadia Maps
///   implementation, still provisional (see TESTING-NOTES.md).
///
/// `defaultTargetPlatform` (not `dart:io`'s `Platform.isIOS`, which throws
/// on web — this codebase already builds for web per `CLAUDE.md`'s
/// documented commands) is the platform check, since there's no existing
/// runtime platform-branching convention elsewhere in this codebase to
/// follow instead.
class MapLocationStep extends StatelessWidget {
  const MapLocationStep({super.key, required this.onSubmit});

  final void Function(double lat, double lng, String label) onSubmit;

  @override
  Widget build(BuildContext context) {
    return defaultTargetPlatform == TargetPlatform.iOS
        ? IosMapLocationStep(onSubmit: onSubmit)
        : StadiaMapLocationStep(onSubmit: onSubmit);
  }
}
