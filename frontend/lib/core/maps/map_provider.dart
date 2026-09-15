import 'package:flutter/material.dart' show Color, visibleForTesting;

import 'package:professional_connections_platform/core/config/app_config.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The map providers the Android screens can draw with. iOS is not part of
/// this switch: it renders Apple Maps (apple_maps_flutter) and its own
/// MapKit search, so nothing here is compiled into an iOS build.
///
/// # WHY A SWITCH RATHER THAN A REPLACEMENT
///
/// Stadia's free tier is metered and the app outgrew it; OpenStreetMap-
/// based services (OpenFreeMap tiles, Photon search) are unmetered and
/// need no key. Keeping Stadia selectable costs one enum and lets a build
/// with a paid key opt back in with `--dart-define=MAP_PROVIDER=stadia`,
/// without touching the screens that draw the map.
enum MapProvider {
  osm,
  stadia;

  /// Parsed once from the compile-time define; an unrecognised value falls
  /// back to OSM rather than to a provider that would need a key.
  static MapProvider get current =>
      AppConfig.mapProvider.toLowerCase() == 'stadia'
      ? MapProvider.stadia
      : MapProvider.osm;
}

/// Everything a map widget needs to know about the current provider.
abstract final class MapConfig {
  /// Test-only override of the compile-time provider choice.
  @visibleForTesting
  static MapProvider? debugProviderOverride;

  /// Test-only override for [AppConfig.stadiaMapsApiKey].
  @visibleForTesting
  static String? debugStadiaApiKeyOverride;

  static MapProvider get provider =>
      debugProviderOverride ?? MapProvider.current;

  static String get stadiaApiKey =>
      debugStadiaApiKeyOverride ?? AppConfig.stadiaMapsApiKey;

  /// False only for Stadia without a key. OSM needs nothing.
  static bool get isConfigured =>
      provider == MapProvider.osm || stadiaApiKey.isNotEmpty;

  /// The MapLibre style for the current provider.
  ///
  /// OSM uses OpenFreeMap's `liberty` style in BOTH themes: a full-colour,
  /// light map in the familiar Google Maps idiom (parks green, water blue,
  /// roads white with names), because a map is a document to read, not
  /// chrome to theme. A dark-styled map made the picker look switched off
  /// and hid the landmarks a person orients by. Stadia keeps the one dark
  /// style it always used.
  static String styleUrl() {
    switch (provider) {
      case MapProvider.osm:
        return 'https://tiles.openfreemap.org/styles/liberty';
      case MapProvider.stadia:
        return 'https://tiles.stadiamaps.com/styles/alidade_smooth_dark.json'
            '?api_key=$stadiaApiKey';
    }
  }

  /// The crosshair/marker colour that reads on this provider's tiles: a
  /// marker red on the light OSM map (the pale accent blue vanished into
  /// it), the app accent on Stadia's dark one.
  static Color get pinColor => switch (provider) {
    MapProvider.osm => const Color(0xFFE53935),
    MapProvider.stadia => AppPalette.candyBlue,
  };

  /// The tile licence's credit. OpenFreeMap serves OpenStreetMap data under
  /// ODbL, which requires attribution; on a phone-sized map the accepted
  /// form (OSMF's attribution guideline, and what MapLibre ships) is the
  /// small (i) control in the map's corner, which opens the style's own
  /// credits: OpenFreeMap, OpenMapTiles, OpenStreetMap contributors. The
  /// styles carry that text, so the screens draw no overlay of their own;
  /// they only keep [attributionEnabled] on.
  static const bool attributionEnabled = true;
}
