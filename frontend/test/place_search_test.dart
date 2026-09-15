import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:professional_connections_platform/core/maps/map_provider.dart';
import 'package:professional_connections_platform/core/maps/place_search.dart';

/// # WHAT THIS FILE GUARDS
///
/// The map step is provider-neutral; these tests pin each geocoder's wire
/// contract on its own: Photon's label assembly from OSM tags, the
/// Nominatim fallback for a direct search when Photon is down (and its
/// deliberate absence for type-ahead), Stadia's label passthrough, and the
/// provider switch that decides which one a build gets.
void main() {
  const photonBody = '''
  {"type":"FeatureCollection","features":[
    {"type":"Feature","geometry":{"type":"Point","coordinates":[79.8612,6.9271]},
     "properties":{"name":"Colombo Fort Cafe","street":"Chatham Street","housenumber":"12",
                   "city":"Colombo","country":"Sri Lanka","osm_key":"amenity","osm_value":"cafe"}},
    {"type":"Feature","geometry":{"type":"Point","coordinates":[79.86,6.92]},
     "properties":{"name":"Colombo","city":"Colombo","country":"Sri Lanka"}},
    {"type":"Feature","geometry":{"type":"Point","coordinates":[79.9,6.9]},
     "properties":{"osm_key":"place"}}
  ]}''';

  group('PhotonPlaceSearch', () {
    test('assembles a readable label from OSM tags, deduplicated, and skips '
        'features with nothing to show', () async {
      late Uri seen;
      late Map<String, String> headers;
      final client = MockClient((request) async {
        seen = request.url;
        headers = request.headers;
        return http.Response(photonBody, 200);
      });

      final results = await PhotonPlaceSearch(
        client,
      ).suggest('colombo', focusLat: 6.9, focusLng: 79.8);

      expect(seen.host, 'photon.komoot.io');
      expect(seen.queryParameters['q'], 'colombo');
      expect(seen.queryParameters['lat'], '6.9');
      expect(seen.queryParameters['lon'], '79.8');
      expect(seen.queryParameters['limit'], '6');
      // Identified traffic, as both OSM services ask.
      expect(headers['User-Agent'], contains('TieHere'));

      expect(results, hasLength(2));
      expect(
        results.first.label,
        'Colombo Fort Cafe, Chatham Street 12, Colombo, Sri Lanka',
      );
      expect(results.first.latitude, 6.9271);
      expect(results.first.longitude, 79.8612);
      // "Colombo" appears as name AND city: once in the label.
      expect(results[1].label, 'Colombo, Sri Lanka');
    });

    test('a non-200 gives an empty suggestion list, never a throw', () async {
      final client = MockClient((_) async => http.Response('nope', 503));
      final results = await PhotonPlaceSearch(
        client,
      ).suggest('x', focusLat: 0, focusLng: 0);
      expect(results, isEmpty);
    });

    test('direct search falls back to Nominatim when Photon fails, but '
        'suggestions never do (Nominatim forbids type-ahead)', () async {
      final hosts = <String>[];
      final client = MockClient((request) async {
        hosts.add(request.url.host);
        if (request.url.host == 'photon.komoot.io') {
          return http.Response('down', 503);
        }
        expect(request.url.queryParameters['format'], 'jsonv2');
        expect(request.url.queryParameters['limit'], '1');
        expect(request.headers['User-Agent'], contains('TieHere'));
        return http.Response(
          '[{"display_name":"Galle Face Green, Colombo","lat":"6.9270","lon":"79.8450"}]',
          200,
        );
      });
      final search = PhotonPlaceSearch(client);

      final hit = await search.search(
        'galle face',
        focusLat: 6.9,
        focusLng: 79.8,
      );
      expect(hit?.label, 'Galle Face Green, Colombo');
      expect(hit?.latitude, closeTo(6.927, 1e-6));
      expect(hosts, ['photon.komoot.io', 'nominatim.openstreetmap.org']);

      hosts.clear();
      final suggestions = await search.suggest(
        'galle',
        focusLat: 6.9,
        focusLng: 79.8,
      );
      expect(suggestions, isEmpty);
      expect(hosts, ['photon.komoot.io']);
    });
  });

  group('StadiaPlaceSearch', () {
    test('passes the key and focus, and takes the label as given', () async {
      late Uri seen;
      final client = MockClient((request) async {
        seen = request.url;
        return http.Response(
          '{"type":"FeatureCollection","features":[{"type":"Feature",'
          '"geometry":{"type":"Point","coordinates":[79.86,6.92]},'
          '"properties":{"label":"Cafe Kumbuk, Colombo 07"}}]}',
          200,
        );
      });
      final hit = await StadiaPlaceSearch(
        client,
        apiKey: 'k',
      ).search('kumbuk', focusLat: 6.9, focusLng: 79.8);

      expect(seen.host, 'api.stadiamaps.com');
      expect(seen.path, '/geocoding/v1/search');
      expect(seen.queryParameters['api_key'], 'k');
      expect(seen.queryParameters['focus.point.lat'], '6.9');
      expect(hit?.label, 'Cafe Kumbuk, Colombo 07');
    });
  });

  group('MapConfig', () {
    tearDown(() {
      MapConfig.debugProviderOverride = null;
      MapConfig.debugStadiaApiKeyOverride = null;
    });

    test('OSM is the default and needs no key; its style and geocoder are '
        'the OpenStreetMap-based ones', () {
      expect(MapConfig.provider, MapProvider.osm);
      expect(MapConfig.isConfigured, isTrue);
      expect(
        MapConfig.styleUrl(),
        startsWith('https://tiles.openfreemap.org/'),
      );
      expect(
        placeSearchFor(MockClient((_) async => http.Response('', 200))),
        isA<PhotonPlaceSearch>(),
      );
    });

    test('Stadia is configured only with a key, and then uses its own style '
        'and geocoder', () {
      MapConfig.debugProviderOverride = MapProvider.stadia;
      expect(MapConfig.isConfigured, isFalse);

      MapConfig.debugStadiaApiKeyOverride = 'k';
      expect(MapConfig.isConfigured, isTrue);
      expect(MapConfig.styleUrl(), contains('stadiamaps.com'));
      expect(MapConfig.styleUrl(), contains('api_key=k'));
      expect(
        placeSearchFor(MockClient((_) async => http.Response('', 200))),
        isA<StadiaPlaceSearch>(),
      );
    });
  });
}
