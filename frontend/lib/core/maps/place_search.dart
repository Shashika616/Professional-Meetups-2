import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:professional_connections_platform/core/maps/map_provider.dart';

/// One place a search turned up: the line to show and store, and where it
/// is. Provider-neutral so the map step never learns which service it is
/// talking to.
class PlaceResult {
  const PlaceResult({
    required this.label,
    required this.latitude,
    required this.longitude,
  });

  final String label;
  final double latitude;
  final double longitude;
}

/// Type-ahead suggestions and a direct one-shot search, biased toward a
/// focus point (the map's current centre). Implementations are thin
/// wrappers over one geocoder each; the widget owns debouncing, request
/// generations and every other piece of UI timing.
abstract interface class PlaceSearch {
  Future<List<PlaceResult>> suggest(
    String text, {
    required double focusLat,
    required double focusLng,
  });

  /// The single best match for a complete query, or null.
  Future<PlaceResult?> search(
    String text, {
    required double focusLat,
    required double focusLng,
  });
}

/// The [PlaceSearch] for the current [MapProvider].
PlaceSearch placeSearchFor(http.Client client) => switch (MapConfig.provider) {
  MapProvider.osm => PhotonPlaceSearch(client),
  MapProvider.stadia => StadiaPlaceSearch(
    client,
    apiKey: MapConfig.stadiaApiKey,
  ),
};

/// Sent on every OSM-service request. Both Photon and Nominatim ask that
/// callers identify themselves; anonymous traffic is the first thing they
/// throttle.
const osmUserAgent = 'TieHere/1.0 (professional meetups app)';

/// Photon (komoot's OpenStreetMap geocoder): free, key-free, built for
/// type-ahead, fair-use throttled. Suggestions and direct search are the
/// same endpoint with different limits.
///
/// Direct search falls back to Nominatim when Photon is unavailable
/// (non-200 or unreachable): a person who typed a full address and pressed
/// search should still get an answer, and Nominatim's usage policy permits
/// exactly this one-request-per-user-action pattern (never type-ahead,
/// which is why suggestions do NOT fall back).
class PhotonPlaceSearch implements PlaceSearch {
  PhotonPlaceSearch(this._client, {this.fallback});

  final http.Client _client;

  /// Injected for tests; defaults to Nominatim when null.
  final PlaceSearch? fallback;

  static const _endpoint = 'https://photon.komoot.io/api/';

  @override
  Future<List<PlaceResult>> suggest(
    String text, {
    required double focusLat,
    required double focusLng,
  }) async {
    final response = await _get(text, focusLat, focusLng, limit: 6);
    if (response.statusCode != 200) return const [];
    return _parse(response.body);
  }

  @override
  Future<PlaceResult?> search(
    String text, {
    required double focusLat,
    required double focusLng,
  }) async {
    try {
      final response = await _get(text, focusLat, focusLng, limit: 1);
      if (response.statusCode == 200) {
        final results = _parse(response.body);
        if (results.isNotEmpty) return results.first;
        return null;
      }
    } catch (_) {
      // Fall through to the fallback below.
    }
    final second = fallback ?? NominatimPlaceSearch(_client);
    return second.search(text, focusLat: focusLat, focusLng: focusLng);
  }

  Future<http.Response> _get(
    String text,
    double lat,
    double lng, {
    required int limit,
  }) {
    final uri = Uri.parse(_endpoint).replace(
      queryParameters: {
        'q': text,
        'lat': '$lat',
        'lon': '$lng',
        'limit': '$limit',
        'lang': 'en',
      },
    );
    return _client.get(uri, headers: const {'User-Agent': osmUserAgent});
  }

  static List<PlaceResult> _parse(String body) {
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final features = decoded['features'] as List<dynamic>? ?? const [];
    return features
        .map((f) => _fromFeature(f as Map<String, dynamic>))
        .whereType<PlaceResult>()
        .toList();
  }

  /// Photon returns OSM tags, not a display line, so the label is
  /// assembled: name, street (with number), locality, country, without
  /// repeats. Null for a feature with no usable name or point.
  static PlaceResult? _fromFeature(Map<String, dynamic> feature) {
    final props = feature['properties'] as Map<String, dynamic>? ?? const {};
    final geometry = feature['geometry'] as Map<String, dynamic>?;
    final coords = geometry?['coordinates'] as List<dynamic>?;
    if (coords == null || coords.length != 2) return null;
    String? s(String key) {
      final v = props[key];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    final street = s('street');
    final number = s('housenumber');
    final streetLine = street == null
        ? null
        : (number == null ? street : '$street $number');
    final locality = s('city') ?? s('town') ?? s('village') ?? s('district');
    final parts = <String>[];
    for (final part in [s('name'), streetLine, locality, s('country')]) {
      if (part != null && !parts.contains(part)) parts.add(part);
    }
    if (parts.isEmpty) return null;
    return PlaceResult(
      label: parts.join(', '),
      latitude: (coords[1] as num).toDouble(),
      longitude: (coords[0] as num).toDouble(),
    );
  }
}

/// Nominatim, OpenStreetMap's own geocoder. Direct search only: its usage
/// policy forbids type-ahead, so [suggest] returns nothing and the caller
/// must never route keystrokes here.
class NominatimPlaceSearch implements PlaceSearch {
  const NominatimPlaceSearch(this._client);

  final http.Client _client;

  static const _endpoint = 'https://nominatim.openstreetmap.org/search';

  @override
  Future<List<PlaceResult>> suggest(
    String text, {
    required double focusLat,
    required double focusLng,
  }) async => const [];

  @override
  Future<PlaceResult?> search(
    String text, {
    required double focusLat,
    required double focusLng,
  }) async {
    // A viewbox around the focus biases (bounded=0: does not restrict) the
    // ranking toward the map the user is looking at.
    const half = 0.5;
    final uri = Uri.parse(_endpoint).replace(
      queryParameters: {
        'q': text,
        'format': 'jsonv2',
        'limit': '1',
        'viewbox':
            '${focusLng - half},${focusLat + half},${focusLng + half},${focusLat - half}',
        'bounded': '0',
      },
    );
    final response = await _client.get(
      uri,
      headers: const {'User-Agent': osmUserAgent},
    );
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(response.body) as List<dynamic>;
    if (decoded.isEmpty) return null;
    final first = decoded.first as Map<String, dynamic>;
    final label = first['display_name'] as String?;
    final lat = double.tryParse('${first['lat']}');
    final lon = double.tryParse('${first['lon']}');
    if (label == null || lat == null || lon == null) return null;
    return PlaceResult(label: label, latitude: lat, longitude: lon);
  }
}

/// Stadia Maps' Pelias-based geocoder, the previous provider. Kept for
/// builds that set `MAP_PROVIDER=stadia` with a key.
class StadiaPlaceSearch implements PlaceSearch {
  const StadiaPlaceSearch(this._client, {required this.apiKey});

  final http.Client _client;
  final String apiKey;

  static const _autocomplete =
      'https://api.stadiamaps.com/geocoding/v1/autocomplete';
  static const _search = 'https://api.stadiamaps.com/geocoding/v1/search';

  @override
  Future<List<PlaceResult>> suggest(
    String text, {
    required double focusLat,
    required double focusLng,
  }) async {
    final response = await _client.get(
      _uri(_autocomplete, text, focusLat, focusLng),
    );
    if (response.statusCode != 200) return const [];
    return _parse(response.body);
  }

  @override
  Future<PlaceResult?> search(
    String text, {
    required double focusLat,
    required double focusLng,
  }) async {
    final response = await _client.get(
      _uri(_search, text, focusLat, focusLng, size: 1),
    );
    if (response.statusCode != 200) return null;
    final results = _parse(response.body);
    return results.isEmpty ? null : results.first;
  }

  Uri _uri(String base, String text, double lat, double lng, {int? size}) =>
      Uri.parse(base).replace(
        queryParameters: {
          'api_key': apiKey,
          'text': text,
          'focus.point.lat': '$lat',
          'focus.point.lon': '$lng',
          if (size != null) 'size': '$size',
        },
      );

  static List<PlaceResult> _parse(String body) {
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final features = decoded['features'] as List<dynamic>? ?? const [];
    final out = <PlaceResult>[];
    for (final f in features) {
      final feature = f as Map<String, dynamic>;
      final props = feature['properties'] as Map<String, dynamic>?;
      final coords =
          (feature['geometry'] as Map<String, dynamic>?)?['coordinates']
              as List<dynamic>?;
      final label = props?['label'] as String?;
      if (label == null || coords == null || coords.length != 2) continue;
      out.add(
        PlaceResult(
          label: label,
          latitude: (coords[1] as num).toDouble(),
          longitude: (coords[0] as num).toDouble(),
        ),
      );
    }
    return out;
  }
}
