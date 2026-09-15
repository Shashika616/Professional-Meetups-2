import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' show LocationAccuracy, Position;

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
/// Medium accuracy: a 40km radius does not need GPS precision, and network
/// positioning answers in a second or two where a GPS fix indoors may not
/// answer at all.
final viewerLocationSourceProvider = Provider<Future<Position> Function()>(
  (ref) =>
      () => requestCurrentLocation(accuracy: LocationAccuracy.medium),
);

enum ViewerLocationStatus { loading, blocked, ready }

/// Rounded to three decimals (~110m) so two reads from a device that moved
/// three metres on a desk produce the same provider key and the same
/// cached page, instead of a refetch. The exact position still goes to
/// `updateLastKnownLocation`; only what the UI keys on is quantised.
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
      // must never hold up the list.
      unawaited(
        ref
            .read(authServiceProvider)
            .updateLastKnownLocation(
              latitude: position.latitude,
              longitude: position.longitude,
            )
            .catchError(
              // TYPE AND A FIXED MESSAGE, never the raw error object:
              // debugPrint survives release builds and a PlatformException's
              // toString() can carry more than intended.
              (Object error) => debugPrint(
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
