import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart'
    show Geolocator, LocationAccuracy, LocationPermission, Position;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:professional_connections_platform/core/utils/debug_log.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/utils/location.dart';

/// Where Home's browse list thinks the viewer is, and how that read is
/// going.
///
/// # WHY THIS IS A PROVIDER AND NOT SECTION STATE
///
/// The read used to start in HappeningSoonSection's initState. Home is one
/// lazy ListView, and on a phone with two or three active meetups that
/// section sits below the fold, so it was not BUILT until the user
/// scrolled, and neither was the permission prompt nor the fix. The user
/// saw a page, scrolled, and only then got asked for location, which reads
/// as the app waking up late. Owning the read here lets HomePage start it
/// the moment the page mounts, and lets the section, the pull-to-refresh
/// and the retry button all drive the same one read.
///
/// autoDispose on purpose: it lives exactly as long as something on Home
/// watches it, so a sign-out and sign-in starts clean.
final viewerLocationProvider =
    NotifierProvider.autoDispose<ViewerLocationNotifier, ViewerLocation>(
      ViewerLocationNotifier.new,
    );

/// The position source, overridable in tests (and by anything that wants a
/// different accuracy trade-off) without touching the platform singleton.
/// Medium accuracy: a 50 km radius does not need GPS precision, and network
/// positioning answers in a second or two where a GPS fix indoors may not
/// answer at all.
///
/// Tighter limits than the helper's defaults, on purpose. This read gates
/// the first thing Home shows, and the only thing the full budget bought
/// was a longer stare at the skeleton when nothing was coming: a phone
/// that can answer does so in the first two seconds, and a phone that
/// cannot is better served by the location card and its TRY AGAIN after
/// eleven seconds than after twenty-six. SOS keeps the long budget; a
/// browse list does not need it.
final viewerLocationSourceProvider = Provider<Future<Position> Function()>(
  (ref) =>
      () => requestCurrentLocation(
        accuracy: LocationAccuracy.medium,
        timeLimit: browseFixTimeLimit,
        gpsFallbackLimit: browseGpsFallbackLimit,
      ),
);

/// How long the browse read waits on the cheap (network) fix.
const browseFixTimeLimit = Duration(seconds: 6);

/// How long its one GPS retry may take after that.
const browseGpsFallbackLimit = Duration(seconds: 5);

enum ViewerLocationStatus {
  loading,

  /// The system has not asked yet and the app has not explained why it
  /// will: HomePage shows [LocationExplanationPage] and answers.
  needsExplanation,
  blocked,
  ready,
}

/// Whether the explanation screen is still owed (plan 3.3).
abstract interface class LocationExplanation {
  /// True when the system prompt has not been shown and neither has the
  /// explanation.
  Future<bool> needed();

  /// Remembers that the person has read it and chose to continue.
  Future<void> markShown();
}

class DeviceLocationExplanation implements LocationExplanation {
  const DeviceLocationExplanation();

  static const _key = 'location.explained';

  @override
  Future<bool> needed() async {
    try {
      if (await Geolocator.checkPermission() != LocationPermission.denied) {
        return false;
      }
      final prefs = await SharedPreferences.getInstance();
      return !(prefs.getBool(_key) ?? false);
    } catch (_) {
      // Never a reason to hold up the list: the read asks for itself.
      return false;
    }
  }

  @override
  Future<void> markShown() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, true);
    } catch (_) {}
  }
}

final locationExplanationProvider = Provider<LocationExplanation>(
  (ref) => const DeviceLocationExplanation(),
);

/// The last position a browse read found, rounded, or null. Read-only and
/// never starts a read, so a screen outside Home can use a location the app
/// already has without touching the location service (N1-D1). Cleared when
/// the signed-in user changes.
final knownViewerLocationProvider =
    NotifierProvider<KnownViewerLocation, ({double lat, double lng})?>(
      KnownViewerLocation.new,
    );

class KnownViewerLocation extends Notifier<({double lat, double lng})?> {
  @override
  ({double lat, double lng})? build() {
    ref.watch(authSessionProvider.select((s) => s.value?.session?.userId));
    return null;
  }

  void set(({double lat, double lng}) position) => state = position;
}

/// Rounded to three decimals (~110m), so two reads from a device that moved
/// three metres on a desk produce the same provider key and the same cached
/// page, and so the exact position never leaves the phone (N1-D1): the
/// server is sent this rounded value too.
@visibleForTesting
double quantiseViewerCoordinate(double value) =>
    (value * 1000).roundToDouble() / 1000;

@immutable
class ViewerLocation {
  const ViewerLocation._({
    required this.status,
    this.lat,
    this.lng,
    this.blockReason,
    this.slow = false,
  });

  const ViewerLocation.loading() : this._(status: ViewerLocationStatus.loading);

  const ViewerLocation.needsExplanation()
    : this._(status: ViewerLocationStatus.needsExplanation);

  final ViewerLocationStatus status;

  /// Quantised viewer coordinates; set only when [status] is ready.
  final double? lat;
  final double? lng;

  /// Why the read failed; set only when [status] is blocked.
  final LocationUnavailableException? blockReason;

  /// True once a loading read has run past [ViewerLocationNotifier.slowAfter]
  /// without resolving, so the UI can say so rather than shimmer in silence.
  final bool slow;

  ViewerLocation _copyWith({bool? slow}) => ViewerLocation._(
    status: status,
    lat: lat,
    lng: lng,
    blockReason: blockReason,
    slow: slow ?? this.slow,
  );
}

class ViewerLocationNotifier extends Notifier<ViewerLocation> {
  /// How long a read may run before the UI is told it is slow. Long enough
  /// that a normal network fix never trips it; short enough that nobody
  /// stares at a shimmer wondering whether the app is doing anything.
  static const slowAfter = Duration(seconds: 5);

  Timer? _slowTimer;
  int _generation = 0;

  /// The last position reported to the server, rounded, and when. A pull to
  /// refresh re-reads the location, but re-sending an unchanged one costs a
  /// request and a radio wake-up for nothing.
  ({double lat, double lng})? _lastReported;
  DateTime? _lastReportedAt;

  /// How long an unchanged position is trusted before it is sent again.
  /// The server ignores cached locations older than a day, so an hour keeps
  /// it comfortably fresh.
  static const reportAgainAfter = Duration(hours: 1);

  @override
  ViewerLocation build() {
    ref.onDispose(() => _slowTimer?.cancel());
    // Starts on first listen. HomePage listens from its initState, so the
    // read (and the permission prompt) begins when the page mounts, not
    // when the browse section scrolls into view.
    unawaited(refresh());
    return const ViewerLocation.loading();
  }

  /// Runs (or re-runs) the read. Concurrent calls are collapsed: only the
  /// newest one may write state, so a slow first read cannot land after a
  /// faster retry and clobber it.
  Future<void> refresh() async {
    final generation = ++_generation;
    _slowTimer?.cancel();
    // A position already on screen stays there while a newer one is
    // fetched: pull-to-refresh must not swap the list for a skeleton. Only
    // a first read, or a retry from a blocked state, shows loading.
    // stateOrNull: on the very first call, from build(), there is no state
    // yet and reading `state` would throw.
    if (stateOrNull?.status != ViewerLocationStatus.ready) {
      state = const ViewerLocation.loading();
      _slowTimer = Timer(slowAfter, () {
        if (generation == _generation &&
            stateOrNull?.status == ViewerLocationStatus.loading) {
          state = state._copyWith(slow: true);
        }
      });
    }
    if (await ref.read(locationExplanationProvider).needed()) {
      if (generation != _generation) return;
      _slowTimer?.cancel();
      state = const ViewerLocation.needsExplanation();
      return;
    }
    if (generation != _generation) return;
    await _read(generation);
  }

  /// The person read the explanation and chose to continue.
  Future<void> explanationAccepted() async {
    await ref.read(locationExplanationProvider).markShown();
    final generation = ++_generation;
    state = const ViewerLocation.loading();
    await _read(generation);
  }

  /// Not now: nothing is asked, and Try again offers the explanation again.
  void explanationDeclined() {
    ++_generation;
    state = const ViewerLocation._(
      status: ViewerLocationStatus.blocked,
      blockReason: LocationUnavailableException(
        'Turn on location to see meetups near you.',
        reason: LocationUnavailableReason.other,
      ),
    );
  }

  Future<void> _read(int generation) async {
    try {
      final position = await ref.read(viewerLocationSourceProvider)();
      if (generation != _generation) return;
      _slowTimer?.cancel();
      state = ViewerLocation._(
        status: ViewerLocationStatus.ready,
        lat: quantiseViewerCoordinate(position.latitude),
        lng: quantiseViewerCoordinate(position.longitude),
      );
      // The app's one trigger for the server-side last-known location
      // (nearby-meetup notifications). Fire-and-forget: a slow call here
      // must never hold up the list. Skipped when nothing has changed.
      final rounded = (lat: state.lat!, lng: state.lng!);
      ref.read(knownViewerLocationProvider.notifier).set(rounded);
      final now = DateTime.now();
      if (rounded == _lastReported &&
          _lastReportedAt != null &&
          now.difference(_lastReportedAt!) < reportAgainAfter) {
        return;
      }
      unawaited(
        ref
            .read(authServiceProvider)
            .updateLastKnownLocation(
              latitude: rounded.lat,
              longitude: rounded.lng,
            )
            // Recorded only once the server has it, so a failed send is
            // retried on the next refresh rather than an hour later.
            .then((_) {
              _lastReported = rounded;
              _lastReportedAt = now;
            })
            .catchError(
              // TYPE AND A FIXED MESSAGE, never the raw error object,
              // and debug builds only (#94): a PlatformException's
              // toString() can carry more than intended.
              (Object error) => debugLog(
                'updateLastKnownLocation failed: ${error.runtimeType}',
              ),
            ),
      );
    } on LocationUnavailableException catch (error) {
      if (generation != _generation) return;
      _slowTimer?.cancel();
      // A refresh that fails while a position is already shown keeps the
      // position: the last fix is a better answer than a blocked card.
      if (stateOrNull?.status == ViewerLocationStatus.ready) return;
      state = ViewerLocation._(
        status: ViewerLocationStatus.blocked,
        blockReason: error,
      );
    }
  }
}
