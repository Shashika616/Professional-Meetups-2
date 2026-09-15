import 'dart:async' show TimeoutException;

import 'package:geolocator/geolocator.dart';

/// Distinguishes *why* [requestCurrentLocation] failed — lets a caller
/// offer the right fix (open location settings vs. open app permission
/// settings vs. just "try again") instead of parsing [LocationUnavailableException
/// .message] to guess (Slice D, `frontend/geo-visibility-PLAN.md` Step 2's
/// blur+prompt state needs this; the SOS flow that introduced this
/// exception type didn't, so this is new as of this slice).
enum LocationUnavailableReason {
  servicesDisabled,
  permissionDenied,

  /// The device could not produce a fix within the deadline and had no
  /// recent one to fall back on: indoors, no signal, or a cold GPS.
  timedOut,
  other,
}

/// Thrown by [requestCurrentLocation] — [message] is a human-readable
/// string safe to show directly (mirrors the map picker's own inline error
/// copy); [reason] is for callers that need to react differently per case.
class LocationUnavailableException implements Exception {
  const LocationUnavailableException(
    this.message, {
    this.reason = LocationUnavailableReason.other,
  });

  final String message;
  final LocationUnavailableReason reason;

  @override
  String toString() => message;
}

/// The permission-check-and-fetch sequence already used by the schedule
/// flow's map location step (`ios_map_location_step.dart`/
/// `android_map_location_step.dart`'s own `_useCurrentLocation`) — extracted
/// here so the SOS flow's fresh on-demand location read (ADR-026 §6,
/// `frontend/sos-trusted-contacts-PLAN.md` Step 3) reuses the exact same
/// plumbing instead of a third, separately-maintained copy. The two
/// existing map-step widgets are left as they are (a working, already-
/// tested platform-split feature outside this batch's scope) rather than
/// refactored to call this too — this is for new callers going forward.
///
/// # WHY THERE IS A DEADLINE, AND A FALLBACK
///
/// `getCurrentPosition` with no time limit waits for a FRESH fix, and on
/// Android indoors that can be tens of seconds or never. Home sat on a
/// shimmer the whole time with nothing to say. So: ask for a fix with a
/// [timeLimit]; if it does not arrive, take the platform's last known
/// position (a 40km browse radius does not need metre accuracy or a fix
/// from this minute); only with neither is the caller told, as
/// [LocationUnavailableReason.timedOut], with a sentence it can show.
///
/// [accuracy] defaults to high. Browsing passes medium, which lets the
/// platform answer from network positioning in a second or two instead of
/// waiting on GPS; SOS keeps the default.
Future<Position> requestCurrentLocation({
  Duration timeLimit = const Duration(seconds: 12),
  LocationAccuracy accuracy = LocationAccuracy.high,
  bool fallbackToLastKnown = true,
}) async {
  // Every failure leaves as LocationUnavailableException, including a
  // platform-channel one from the service/permission probes themselves
  // (a missing plugin, a device with no location service at all). Callers
  // catch exactly that type; anything else would escape as an unhandled
  // error from a fire-and-forget read.
  try {
    // An outer deadline over the WHOLE sequence, not just the fix: the
    // service and permission probes are platform calls too, and a channel
    // that never answers (seen under flutter_test with no handler; not
    // impossible on a misbehaving device) would otherwise hold the caller
    // forever. A few seconds past the fix's own limit is enough for the
    // fallback read to run.
    return await _requestCurrentLocation(
      timeLimit: timeLimit,
      accuracy: accuracy,
      fallbackToLastKnown: fallbackToLastKnown,
    ).timeout(timeLimit + const Duration(seconds: 4));
  } on LocationUnavailableException {
    rethrow;
  } on TimeoutException {
    throw const LocationUnavailableException(
      'Couldn\'t pin down your location. Move somewhere with a clearer '
      'signal, or check that location is on, and try again.',
      reason: LocationUnavailableReason.timedOut,
    );
  } catch (_) {
    throw const LocationUnavailableException(
      'Could not get your current location.',
    );
  }
}

Future<Position> _requestCurrentLocation({
  required Duration timeLimit,
  required LocationAccuracy accuracy,
  required bool fallbackToLastKnown,
}) async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw const LocationUnavailableException(
      'Turn on location services to use this.',
      reason: LocationUnavailableReason.servicesDisabled,
    );
  }

  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    throw const LocationUnavailableException(
      'Location permission was denied. Enable it in Settings to use this.',
      reason: LocationUnavailableReason.permissionDenied,
    );
  }

  try {
    return await Geolocator.getCurrentPosition(
      locationSettings: LocationSettings(
        accuracy: accuracy,
        timeLimit: timeLimit,
      ),
    );
  } on TimeoutException {
    if (fallbackToLastKnown) {
      final last = await _lastKnownOrNull();
      if (last != null) return last;
    }
    throw const LocationUnavailableException(
      'Couldn\'t pin down your location. Move somewhere with a clearer '
      'signal, or check that location is on, and try again.',
      reason: LocationUnavailableReason.timedOut,
    );
  } catch (_) {
    if (fallbackToLastKnown) {
      final last = await _lastKnownOrNull();
      if (last != null) return last;
    }
    throw const LocationUnavailableException(
      'Could not get your current location.',
    );
  }
}

/// A last known position, or null. Wrapped because the platform call can
/// itself throw on some devices, and a failure here must never mask the
/// original reason the fresh fix failed.
Future<Position?> _lastKnownOrNull() async {
  try {
    return await Geolocator.getLastKnownPosition();
  } catch (_) {
    return null;
  }
}
