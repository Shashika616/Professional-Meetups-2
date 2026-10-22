import 'dart:convert';
import 'dart:math' as math;

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

/// How long any one geocoder request may take before it is abandoned.
///
/// These are free, shared, fair-use services and a slow one used to hang
/// the dropdown open on a spinner with no end: there was no timeout at
/// all. Ten seconds is past the point where a person has already decided
/// the feature is broken, so it is the outer bound, not the target.
const geocoderTimeout = Duration(seconds: 10);

/// Half the side of the box a suggestion search is confined to, in
/// degrees — about 39km north/south, and the same at Colombo's latitude.
///
/// # WHY SUGGESTIONS ARE BOXED AND NOT MERELY BIASED
///
/// Photon takes `lat`/`lon` as a *bias*, which in practice it applies
/// weakly: typing "coffee" with the map on Colombo returned five places
/// in the United States and Iraq before a single Sri Lankan one. A person
/// picking somewhere to meet is picking somewhere they can get to, so the
/// box is a filter, not a hint — and when it catches nothing the search
/// runs again unbounded, so looking up another city still works.
const _suggestHalfSpanDegrees = 0.35;

/// Nearest first, with a strong thumb on the scale for a name that
/// actually matches what was typed.
///
/// Distance alone would float an unnamed corner shop above the landmark
/// someone is typing the name of; relevance alone is what produced the
/// results-in-Iraq ranking above. So: a result whose name equals the
/// query, or starts with it, is credited the equivalent of several
/// kilometres, and everything else sorts by how far away it is.
List<PlaceResult> rankPlacesByProximity(
  List<PlaceResult> results,
  String query,
  double focusLat,
  double focusLng,
) {
  final q = query.trim().toLowerCase();
  double score(PlaceResult r) {
    final name = r.label.split(',').first.trim().toLowerCase();
    var s = _distanceKm(focusLat, focusLng, r.latitude, r.longitude);
    if (name == q) {
      s -= 15;
    } else if (name.startsWith(q)) {
      s -= 8;
    }
    return s;
  }

  final ranked = [...results]..sort((a, b) => score(a).compareTo(score(b)));
  // One row per place. Several branches of the same chain come back with
  // byte-identical labels ("Barista, Colombo" four times over), which is
  // a list the user cannot choose from: they all look like the same
  // place. The nearest of each label survives, which after the sort above
  // is simply the first.
  final seen = <String>{};
  return [
    for (final r in ranked)
      if (seen.add(r.label.toLowerCase())) r,
  ];
}

/// Great-circle distance in kilometres (haversine).
double _distanceKm(double lat1, double lng1, double lat2, double lng2) {
  const earthRadiusKm = 6371.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return earthRadiusKm * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
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
    // Local first. The over-fetch (12, not 6) is deliberate: the ranking
    // below reorders and de-duplicates before the list is cut to size, so
    // it needs more than a screenful to work with.
    var results = await _suggestWithin(
      text,
      focusLat,
      focusLng,
      bbox: _bboxAround(focusLat, focusLng),
    );
    // An ANSWERED search that found nothing nearby means the person is
    // looking somewhere else — another city, another country — so ask
    // again without the box rather than telling them there is no such
    // place. A failed search (null) is not retried: the service is down,
    // and a second request to a service that just refused the first is
    // traffic nobody benefits from.
    if (results != null && results.isEmpty) {
      results = await _suggestWithin(text, focusLat, focusLng, bbox: null);
    }
    return rankPlacesByProximity(
      results ?? const [],
      text,
      focusLat,
      focusLng,
    ).take(6).toList();
  }

  /// The matches inside [bbox], or null when the service did not answer.
  Future<List<PlaceResult>?> _suggestWithin(
    String text,
    double focusLat,
    double focusLng, {
    required String? bbox,
  }) async {
    final response = await _get(
      text,
      focusLat,
      focusLng,
      // Over-fetched on purpose: the ranking reorders and de-duplicates
      // before the list is cut to size, so it needs more than a
      // screenful to work with.
      limit: 12,
      bbox: bbox,
    );
    if (response.statusCode != 200) return null;
    return _parse(response.body);
  }

  /// `minLon,minLat,maxLon,maxLat`, Photon's order. Fixed to four
  /// decimals (about 11m, far finer than a 40km box needs) so binary
  /// floating point does not put `6.550000000000001` in a URL.
  static String _bboxAround(double lat, double lng) {
    const d = _suggestHalfSpanDegrees;
    String f(double v) => v.toStringAsFixed(4);
    return '${f(lng - d)},${f(lat - d)},${f(lng + d)},${f(lat + d)}';
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
    String? bbox,
  }) {
    final uri = Uri.parse(_endpoint).replace(
      queryParameters: {
        'q': text,
        'lat': '$lat',
        'lon': '$lng',
        'limit': '$limit',
        'lang': 'en',
        'bbox': ?bbox,
      },
    );
    return _client
        .get(uri, headers: const {'User-Agent': osmUserAgent})
        .timeout(geocoderTimeout);
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
    final response = await _client
        .get(uri, headers: const {'User-Agent': osmUserAgent})
        .timeout(geocoderTimeout);
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
    final response = await _client
        .get(_uri(_autocomplete, text, focusLat, focusLng))
        .timeout(geocoderTimeout);
    if (response.statusCode != 200) return const [];
    return rankPlacesByProximity(
      _parse(response.body),
      text,
      focusLat,
      focusLng,
    ).take(6).toList();
  }

  @override
  Future<PlaceResult?> search(
    String text, {
    required double focusLat,
    required double focusLng,
  }) async {
    final response = await _client
        .get(_uri(_search, text, focusLat, focusLng, size: 1))
        .timeout(geocoderTimeout);
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
