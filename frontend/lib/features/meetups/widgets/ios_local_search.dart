import 'package:flutter/services.dart';

/// Thin Dart wrapper around the native `MethodChannel` bridging to
/// `MKLocalSearchCompleter`/`MKLocalSearch` (`ios/Runner/LocalSearchChannel.swift`)
/// — `apple_maps_flutter` only renders the map, it doesn't expose MapKit's
/// search APIs, so this bridges to them directly rather than silently
/// downgrading iOS to a weaker search experience than what MapKit natively
/// offers (frontend/meetup-scheduling-PLAN.md's 2026-08-18 platform-split
/// addendum, Step 2).
///
/// A raw `MKLocalSearchCompletion` can't cross the platform channel
/// boundary, so [autocomplete] returns lightweight title/subtitle pairs
/// and the native side keeps the last batch in memory; [resolveCompletion]
/// asks it to resolve one of *those* (by index) to real coordinates via a
/// second native call — this mirrors how MapKit itself requires a second
/// `MKLocalSearch` to resolve a completion, it isn't an extra round trip
/// this wrapper invented.
class IosLocalSearch {
  const IosLocalSearch();

  static const MethodChannel _channel = MethodChannel(
    'professionalconnections/ios_local_search',
  );

  Future<List<IosSearchCompletion>> autocomplete(
    String text, {
    required double lat,
    required double lon,
  }) async {
    final raw = await _channel.invokeMethod<List<dynamic>>('autocomplete', {
      'text': text,
      'lat': lat,
      'lon': lon,
    });
    return (raw ?? [])
        .cast<Map<dynamic, dynamic>>()
        .map(
          (m) => IosSearchCompletion(
            title: m['title'] as String? ?? '',
            subtitle: m['subtitle'] as String? ?? '',
          ),
        )
        .toList();
  }

  /// [index] must refer to the most recent [autocomplete] batch — the
  /// native side only remembers one batch at a time (a fresh
  /// `autocomplete` call replaces it), matching how the Dart-side debounce
  /// only ever cares about the latest query anyway.
  Future<IosSearchResult> resolveCompletion(int index) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'resolveCompletion',
      {'index': index},
    );
    return IosSearchResult._fromChannel(raw!);
  }

  /// The "type a complete query and press search/return" path — a direct
  /// `MKLocalSearch`, not the completer.
  Future<IosSearchResult> search(
    String text, {
    required double lat,
    required double lon,
  }) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('search', {
      'text': text,
      'lat': lat,
      'lon': lon,
    });
    return IosSearchResult._fromChannel(raw!);
  }
}

/// One `MKLocalSearchCompletion` — display-only until resolved via
/// [IosLocalSearch.resolveCompletion] (it carries no coordinates itself,
/// same as the native type it mirrors).
class IosSearchCompletion {
  const IosSearchCompletion({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  String get displayLabel => subtitle.isEmpty ? title : '$title, $subtitle';
}

/// A resolved location — either from [IosLocalSearch.resolveCompletion] or
/// [IosLocalSearch.search].
class IosSearchResult {
  const IosSearchResult({
    required this.lat,
    required this.lon,
    required this.label,
  });

  final double lat;
  final double lon;
  final String label;

  factory IosSearchResult._fromChannel(Map<dynamic, dynamic> map) {
    return IosSearchResult(
      lat: (map['lat'] as num).toDouble(),
      lon: (map['lon'] as num).toDouble(),
      label: map['label'] as String? ?? '',
    );
  }
}
