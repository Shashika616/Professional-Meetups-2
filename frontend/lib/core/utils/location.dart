import 'package:geolocator/geolocator.dart';

/// Distinguishes *why* [requestCurrentLocation] failed — lets a caller
/// offer the right fix (open location settings vs. open app permission
/// settings vs. just "try again") instead of parsing [LocationUnavailableException
/// .message] to guess (Slice D, `frontend/geo-visibility-PLAN.md` Step 2's
/// blur+prompt state needs this; the SOS flow that introduced this
/// exception type didn't, so this is new as of this slice).
enum LocationUnavailableReason { servicesDisabled, permissionDenied, other }

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
/// `stadia_map_location_step.dart`'s own `_useCurrentLocation`) — extracted
/// here so the SOS flow's fresh on-demand location read (ADR-026 §6,
/// `frontend/sos-trusted-contacts-PLAN.md` Step 3) reuses the exact same
/// plumbing instead of a third, separately-maintained copy. The two
/// existing map-step widgets are left as they are (a working, already-
/// tested platform-split feature outside this batch's scope) rather than
/// refactored to call this too — this is for new callers going forward.
Future<Position> requestCurrentLocation() async {
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
    return await Geolocator.getCurrentPosition();
  } catch (_) {
    throw const LocationUnavailableException(
      'Could not get your current location.',
    );
  }
}
