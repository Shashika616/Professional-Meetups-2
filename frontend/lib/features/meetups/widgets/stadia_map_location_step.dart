// ignore_for_file: prefer_initializing_formals
// StadiaMapLocationStep's public `httpClient` param name deliberately
// differs from the private `_httpClient` field it initializes — same
// tradeoff as token_refresher.dart's own doc comment on this lint.
import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';

import 'package:professional_connections_platform/core/config/app_config.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/glass_text_field.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/step_hero.dart';
import 'package:professional_connections_platform/features/meetups/widgets/selected_place_banner.dart';

/// Android's half of [MapLocationStep]'s platform switch (ADR-013 §4's
/// third correction) — Stadia Maps via `maplibre_gl`, unchanged provider
/// choice from the prior testing addendum (still provisional; see
/// TESTING-NOTES.md). **This is the one file that talks to Stadia Maps.**
///
/// Fixes a real bug from the prior pass: address search fetched and
/// parsed results correctly, but the suggestions dropdown never rendered
/// — `Stack`'s default `clipBehavior` is `Clip.hardEdge`, and the Stack
/// wrapping the search field only sizes itself to the field's own height,
/// so the `Positioned` dropdown below it was silently clipped away every
/// time. See `TESTING-NOTES.md` for the full diagnosis.
class StadiaMapLocationStep extends StatefulWidget {
  const StadiaMapLocationStep({
    super.key,
    required this.onSubmit,
    http.Client? httpClient,
  }) : _httpClient = httpClient;

  final void Function(double lat, double lng, String label) onSubmit;

  /// Overridable so widget tests can inject a fake client and assert on
  /// real request counts (e.g. that debouncing actually collapses several
  /// keystrokes into one request) instead of hitting the real network —
  /// same optional-override pattern `HttpMeetupService`/`HttpAuthService`
  /// already use elsewhere in this codebase. Defaults to a real
  /// `http.Client()`.
  final http.Client? _httpClient;

  @override
  State<StadiaMapLocationStep> createState() => _StadiaMapLocationStepState();
}

/// Colombo Fort — a sane default center for the invite-only Colombo pilot
/// (ADR-005) before the map has a real signal (search, current location).
const _defaultCenter = LatLng(6.9271, 79.8612);

/// Stadia's dark vector style, matching this app's dark glassmorphism UI —
/// confirmed against docs.stadiamaps.com directly, not assumed.
const _stadiaStyleUrl =
    'https://tiles.stadiamaps.com/styles/alidade_smooth_dark.json';

/// Debounced-suggestions endpoint — partial-text completions.
const _stadiaAutocompleteUrl =
    'https://api.stadiamaps.com/geocoding/v1/autocomplete';

/// Direct-submit endpoint (type a full query, press search/return) — same
/// response shape as autocomplete, confirmed against docs.stadiamaps.com,
/// resolves a complete query straight to its best-match coordinates rather
/// than a list of partial completions.
const _stadiaSearchUrl = 'https://api.stadiamaps.com/geocoding/v1/search';

/// Test-only override for [AppConfig.stadiaMapsApiKey] — real code must
/// never set this. Exists so widget tests (e.g. the Schedule flow's
/// capacity-stepper/timing-step tests, which need to get past this step to
/// reach later ones) can exercise the "configured" branch without a real
/// Stadia key. `MapLibreMap` itself renders safely under `flutter_test`
/// with a bogus style URL/key — no native tile fetch happens off the Dart
/// side in that environment — so this carries no platform-view risk.
@visibleForTesting
String? debugStadiaApiKeyOverride;

String get _effectiveApiKey =>
    debugStadiaApiKeyOverride ?? AppConfig.stadiaMapsApiKey;

class _StadiaMapLocationStepState extends State<StadiaMapLocationStep> {
  late final http.Client _httpClient = widget._httpClient ?? http.Client();
  MapLibreMapController? _controller;
  // The submitted location — set directly (synchronously) by every path
  // that picks a location (suggestion select, direct search, current
  // location) rather than read lazily off `_controller.cameraPosition` at
  // submit time. Also kept in sync with manual map drags via
  // onCameraIdle below, so dragging the crosshair after a search still
  // wins. Two benefits over reading the controller directly: it's
  // testable (MapLibreMap never gets a real native platform view under
  // `flutter_test`, so `cameraPosition` never updates there), and it's
  // not dependent on `animateCamera`'s async settle timing on a real
  // device either.
  LatLng _pickedLocation = _defaultCenter;
  final _searchController = TextEditingController();
  List<_GeocodeResult> _results = [];
  bool _searching = false;
  Timer? _debounce;
  int _requestGeneration = 0;
  // Set right before programmatically assigning _searchController.text (on
  // result selection / current-location fill) so that assignment's own
  // listener notification doesn't immediately re-trigger a search for the
  // text we just set — the listener still needs to run for the "user typed
  // this manually" case, so this is a one-shot suppress flag, not a
  // permanently-removed listener.
  bool _suppressNextSearch = false;
  // ADR-029 (round-8 hardening) — set when the user taps "use my current
  // location" and a position is resolved. _useCurrentLocation no longer
  // fills the search field with a hardcoded "Current location" placeholder
  // (that string used to be submitted verbatim as location_label to
  // everyone, forever — fixed by submitting an empty label instead and
  // letting the server reverse-geocode it), so _canContinue needs this
  // separate signal to unlock CONTINUE even while the field stays empty.
  bool _locationPicked = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchTextChanged);
  }

  void _onSearchTextChanged() {
    // The banner and CONTINUE both derive from the field's text, so any
    // change to it must rebuild — including the programmatic assignment
    // that the suppress flag below skips the *search* for.
    if (mounted) setState(() {});
    if (_suppressNextSearch) {
      _suppressNextSearch = false;
      return;
    }
    _onSearchChanged(_searchController.text);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchTextChanged);
    _debounce?.cancel();
    _searchController.dispose();
    // Only close a client we created ourselves — a caller-injected one
    // (tests) is theirs to manage.
    if (widget._httpClient == null) _httpClient.close();
    super.dispose();
  }

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      setState(() => _results = []);
      return;
    }
    // ~300ms is the usual floor for typeahead debouncing (frontend/
    // meetup-scheduling-PLAN.md's 2026-08-18 platform-split addendum,
    // Step 2) — enough to collapse a burst of keystrokes into one request.
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => _fetchSuggestions(text),
    );
  }

  Future<void> _fetchSuggestions(String text) async {
    final generation = ++_requestGeneration;
    setState(() => _searching = true);
    try {
      final focus = _pickedLocation;
      final uri = Uri.parse(_stadiaAutocompleteUrl).replace(
        queryParameters: {
          'api_key': _effectiveApiKey,
          'text': text,
          'focus.point.lat': '${focus.latitude}',
          'focus.point.lon': '${focus.longitude}',
        },
      );
      final response = await _httpClient.get(uri);
      if (generation != _requestGeneration || !mounted) return;
      if (response.statusCode != 200) {
        setState(() => _results = []);
        return;
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final features = decoded['features'] as List<dynamic>? ?? [];
      setState(() {
        _results = features
            .map((f) => _GeocodeResult.fromFeature(f as Map<String, dynamic>))
            .whereType<_GeocodeResult>()
            .toList();
      });
    } catch (_) {
      if (generation == _requestGeneration && mounted) {
        setState(() => _results = []);
      }
    } finally {
      if (generation == _requestGeneration && mounted) {
        setState(() => _searching = false);
      }
    }
  }

  Future<void> _selectResult(_GeocodeResult result) async {
    _debounce?.cancel();
    // Cancelling the Timer above only stops a debounce that hasn't fired
    // yet — it does nothing for a suggestions request that already fired
    // and is still in flight (e.g. from a keystroke just before this tap).
    // Without invalidating its generation too, that stale request can
    // resolve after this selection and overwrite _results, reopening the
    // dropdown right after the user picked an address. _directSearch
    // already does this itself (it starts its own request); this path
    // doesn't start a new request, so it has to bump the generation
    // explicitly instead.
    ++_requestGeneration;
    _suppressNextSearch = true;
    setState(() {
      _searchController.text = result.label;
      _results = [];
      _pickedLocation = result.location;
    });
    await _controller?.animateCamera(
      CameraUpdate.newLatLngZoom(result.location, 15),
    );
  }

  /// The "type a complete query and press search/return" path — a direct
  /// geocode of the typed text, producing the same recenter-and-pin-drop
  /// result as picking a suggestion, without requiring one to be picked
  /// (frontend/meetup-scheduling-PLAN.md's 2026-08-18 platform-split
  /// addendum, Step 2, point 3).
  Future<void> _directSearch(String text) async {
    if (text.trim().isEmpty) return;
    _debounce?.cancel();
    final generation = ++_requestGeneration;
    setState(() {
      _searching = true;
      _results = [];
    });
    try {
      final focus = _pickedLocation;
      final uri = Uri.parse(_stadiaSearchUrl).replace(
        queryParameters: {
          'api_key': _effectiveApiKey,
          'text': text,
          'focus.point.lat': '${focus.latitude}',
          'focus.point.lon': '${focus.longitude}',
          'size': '1',
        },
      );
      final response = await _httpClient.get(uri);
      if (generation != _requestGeneration || !mounted) return;
      if (response.statusCode != 200) {
        _showError('No results for "$text".');
        return;
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final features = decoded['features'] as List<dynamic>? ?? [];
      final result = features.isEmpty
          ? null
          : _GeocodeResult.fromFeature(features.first as Map<String, dynamic>);
      if (result == null) {
        _showError('No results for "$text".');
        return;
      }
      _suppressNextSearch = true;
      setState(() {
        _searchController.text = result.label;
        _pickedLocation = result.location;
      });
      await _controller?.animateCamera(
        CameraUpdate.newLatLngZoom(result.location, 15),
      );
    } catch (_) {
      if (generation == _requestGeneration && mounted) {
        _showError('No results for "$text".');
      }
    } finally {
      if (generation == _requestGeneration && mounted) {
        setState(() => _searching = false);
      }
    }
  }

  Future<void> _useCurrentLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _showError('Turn on location services to use this.');
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _showError(
          'Location permission was denied. Enable it in Settings to use this.',
        );
        return;
      }

      final position = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      final here = LatLng(position.latitude, position.longitude);
      setState(() => _pickedLocation = here);
      await _controller?.animateCamera(CameraUpdate.newLatLngZoom(here, 15));
      // Leave the search field as-is (ADR-029) — no placeholder text is
      // submitted; the server resolves a real label from the coordinates
      // if the field stays empty. _locationPicked is what unlocks CONTINUE
      // in that case.
      setState(() => _locationPicked = true);
    } catch (_) {
      _showError('Could not get your current location.');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  bool get _canContinue =>
      _searchController.text.trim().isNotEmpty || _locationPicked;

  void _submit() {
    widget.onSubmit(
      _pickedLocation.latitude,
      _pickedLocation.longitude,
      _searchController.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_effectiveApiKey.isEmpty) {
      return _NotConfiguredNotice(stepTitle: _stepTitle());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepTitle(),
        // Slimmer than the other steps' banners: the map below is the
        // real picture on this page and needs the height more.
        const StepHero(
          asset: 'assets/images/schedule/location_card.jpg',
          height: 96,
        ),
        const SizedBox(height: 14),
        // Choose a public place — never a stranger's home address
        // (Safety UX Flows.md's pre-meetup safety copy, ADR-013 § 4).
        Text(
          'Choose a public place: A cafe, restaurant, or well-known '
          'venue, not a private residence.',
          style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: 16),
        Stack(
          // clipBehavior: Clip.none (not the Stack default, Clip.hardEdge)
          // is only half of the actual fix — see the file-level doc
          // comment on the bug. The other half: the search field *and*
          // the map live in the same outer Stack (as one Column, painted
          // first) so the suggestions dropdown — a later Stack child,
          // Positioned below the search field — reliably paints *above*
          // the map too, not just above the search field. When the
          // dropdown had its own separate, smaller Stack (scoped to just
          // the search field), unclipping it fixed visibility but left it
          // paint-ordered *underneath* the map for any pixels where an
          // overflowing dropdown happened to overlap the map's bounds —
          // confirmed via a real hit-test failure in this file's own
          // widget tests (a tap on a dropdown item landed on the map's
          // render object instead).
          clipBehavior: Clip.none,
          children: [
            Column(
              children: [
                GlassTextField(
                  controller: _searchController,
                  icon: Icons.search_rounded,
                  hint: 'Search for a cafe, restaurant, or venue',
                  textInputAction: TextInputAction.search,
                  onFieldSubmitted: _directSearch,
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: SizedBox(
                    height: 240,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        MapLibreMap(
                          styleString:
                              '$_stadiaStyleUrl?api_key=$_effectiveApiKey',
                          initialCameraPosition: const CameraPosition(
                            target: _defaultCenter,
                            zoom: 13,
                          ),
                          onMapCreated: (controller) =>
                              _controller = controller,
                          trackCameraPosition: true,
                          // Keeps _pickedLocation in sync if the user
                          // drags the map (manually adjusting the pin)
                          // after a search — search/current-location
                          // already set it directly and synchronously
                          // (see their own comments), this only matters
                          // for the "no search, just drag the crosshair"
                          // path.
                          onCameraIdle: () {
                            final target = _controller?.cameraPosition?.target;
                            if (target != null) _pickedLocation = target;
                          },
                        ),
                        // Fixed center crosshair — the picked location is
                        // always wherever the map is centered (simpler
                        // and less error-prone than a tap-to-place
                        // gesture, per the plan's own call).
                        IgnorePointer(
                          child: Icon(
                            Icons.location_on,
                            color: AppPalette.candyBlue,
                            size: 36,
                            shadows: [
                              Shadow(
                                color: AppPalette.onyx.withValues(alpha: 0.6),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // What CONTINUE will actually submit, said out loud. Before
                // this, "use my current location" lit CONTINUE with no
                // visible change other than the map recentring — nothing
                // told the user a place had been chosen, or which. The
                // typed/picked name is shown when there is one; the
                // current-location path submits an empty label on purpose
                // (ADR-029, the server reverse-geocodes it), so that case
                // says so instead of showing a blank.
                if (_canContinue) ...[
                  SelectedPlaceBanner(label: _searchController.text.trim()),
                  const SizedBox(height: 12),
                ],
                OutlinedButton.icon(
                  onPressed: _useCurrentLocation,
                  icon: Icon(
                    Icons.my_location_rounded,
                    size: 16,
                    color: AppPalette.candyBlue,
                  ),
                  label: Text(
                    'USE MY CURRENT LOCATION',
                    style: TextStyle(
                      color: AppPalette.candyBlue,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.0,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(42),
                    side: BorderSide(color: AppPalette.hairline),
                  ),
                ),
                const SizedBox(height: 20),
                PrimaryButton(
                  label: 'CONTINUE',
                  onPressed: _canContinue ? _submit : null,
                ),
              ],
            ),
            // Dims and blocks everything behind the dropdown (map, USE MY
            // CURRENT LOCATION, CONTINUE) so none of it shows or is
            // tappable through the suggestions list — without this, those
            // later Column siblings painted *after* this Stack in z-order,
            // so an overflowing dropdown was rendering visually underneath
            // CONTINUE instead of above it. Tapping the scrim dismisses
            // the dropdown without picking a result, same as any standard
            // search-then-pick overlay. Starts at top: 56 (the search
            // field's own height), not Positioned.fill — covering the
            // field too blurred/darkened the text being typed, making it
            // unreadable while the dropdown was open.
            //
            // The ClipRect here is load-bearing, not decorative:
            // BackdropFilter is NOT clipped to its own widget bounds by
            // default — its blur samples/paints across the whole layer
            // behind it (worse still since this Stack is Clip.none), so
            // without this it bled upward into the search field, the step
            // title, and the header above this widget entirely, which is
            // exactly why the field stayed unreadable even after adding
            // the top: 56 offset above.
            if (_results.isNotEmpty)
              Positioned(
                top: 56,
                left: 0,
                right: 0,
                bottom: 0,
                child: ClipRect(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _results = []),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                      child: Container(
                        color: AppPalette.onyx.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ),
              ),
            if (_searching)
              Positioned(
                right: 14,
                top: 0,
                height: 56,
                child: Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppPalette.candyBlue,
                    ),
                  ),
                ),
              ),
            if (_results.isNotEmpty)
              Positioned(
                top: 56,
                left: 0,
                right: 0,
                child: _ResultsDropdown(
                  results: _results,
                  onSelect: _selectResult,
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _stepTitle() {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 20),
      child: Text(
        'Where?',
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w800,
          color: AppPalette.textPrimary,
          height: 1.2,
        ),
      ),
    );
  }
}

class _NotConfiguredNotice extends StatelessWidget {
  const _NotConfiguredNotice({required this.stepTitle});

  final Widget stepTitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        stepTitle,
        FlatCard(
          radius: 12,
          padding: const EdgeInsets.all(16),
          tint: AppPalette.danger.withValues(alpha: 0.08),
          border: AppPalette.danger.withValues(alpha: 0.3),
          child: Text(
            'Location search isn\'t configured for this build — no map '
            'access key was provided. Ask whoever built this app to pass '
            'one, or use the manual-entry fallback in the code until then.',
            style: TextStyle(color: AppPalette.danger, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _ResultsDropdown extends StatelessWidget {
  const _ResultsDropdown({required this.results, required this.onSelect});

  final List<_GeocodeResult> results;
  final void Function(_GeocodeResult result) onSelect;

  @override
  Widget build(BuildContext context) {
    // Solid, not glass — a blurred/translucent dropdown sitting over the
    // map made the suggestion text unreadable against whatever terrain
    // colors were behind it. This needs to read like a standard opaque
    // dropdown, so it stays legible regardless of what's underneath.
    return Material(
      color: AppPalette.card,
      elevation: 12,
      shadowColor: Colors.black87,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppPalette.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      // Caps the list to roughly 5 visible rows and scrolls internally
      // beyond that — an unbounded Column here could grow the dropdown
      // past the whole screen when Stadia returns a long results list.
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxHeight: _maxVisibleDropdownResults * _dropdownItemHeight,
        ),
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 4),
          shrinkWrap: true,
          itemCount: results.length,
          itemBuilder: (context, index) {
            final result = results[index];
            return ListTile(
              dense: true,
              leading: Icon(
                Icons.place_outlined,
                size: 18,
                color: AppPalette.candyBlue,
              ),
              title: Text(
                result.label,
                style: TextStyle(color: AppPalette.textPrimary, fontSize: 13),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => onSelect(result),
            );
          },
        ),
      ),
    );
  }
}

const _maxVisibleDropdownResults = 5;
const _dropdownItemHeight = 60.0;

/// One Stadia geocoding result — only what this widget needs (label to
/// display/store, coordinates to recenter the map on selection).
class _GeocodeResult {
  const _GeocodeResult({required this.label, required this.location});

  final String label;
  final LatLng location;

  /// Returns null for a malformed feature rather than throwing — a single
  /// bad result shouldn't break the whole dropdown.
  static _GeocodeResult? fromFeature(Map<String, dynamic> feature) {
    final properties = feature['properties'] as Map<String, dynamic>?;
    final geometry = feature['geometry'] as Map<String, dynamic>?;
    final coordinates = geometry?['coordinates'] as List<dynamic>?;
    final label = properties?['label'] as String?;
    if (label == null || coordinates == null || coordinates.length != 2) {
      return null;
    }
    // GeoJSON order is [lon, lat], not [lat, lon].
    final lon = (coordinates[0] as num).toDouble();
    final lat = (coordinates[1] as num).toDouble();
    return _GeocodeResult(label: label, location: LatLng(lat, lon));
  }
}
