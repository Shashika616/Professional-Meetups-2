// ignore_for_file: prefer_initializing_formals
// AndroidMapLocationStep's public `httpClient` param name deliberately
// differs from the private `_httpClient` field it initializes — same
// tradeoff as token_refresher.dart's own doc comment on this lint.
import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';

import 'package:professional_connections_platform/core/maps/map_provider.dart';
import 'package:professional_connections_platform/core/maps/place_search.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/meetups/widgets/place_search_ui.dart';
import 'package:professional_connections_platform/core/widgets/step_hero.dart';
import 'package:professional_connections_platform/features/meetups/widgets/selected_place_banner.dart';

/// Android's half of [MapLocationStep]'s platform switch (ADR-013 §4's
/// third correction): a MapLibre map with a crosshair, a type-ahead place
/// search, and "use my current location". Which tiles and which geocoder
/// is decided by [MapConfig] (OpenStreetMap-based OpenFreeMap + Photon by
/// default, Stadia by build flag); this widget talks to neither directly.
///
/// Fixes a real bug from the prior pass: address search fetched and
/// parsed results correctly, but the suggestions dropdown never rendered
/// — `Stack`'s default `clipBehavior` is `Clip.hardEdge`, and the Stack
/// wrapping the search field only sizes itself to the field's own height,
/// so the `Positioned` dropdown below it was silently clipped away every
/// time. See `TESTING-NOTES.md` for the full diagnosis.
class AndroidMapLocationStep extends StatefulWidget {
  const AndroidMapLocationStep({
    super.key,
    required this.onSubmit,
    http.Client? httpClient,
    this.placeSearch,
  }) : _httpClient = httpClient;

  final void Function(double lat, double lng, String label) onSubmit;

  /// Overridable so widget tests can inject a fake client and assert on
  /// real request counts (e.g. that debouncing actually collapses several
  /// keystrokes into one request) instead of hitting the real network —
  /// same optional-override pattern `HttpMeetupService`/`HttpAuthService`
  /// already use elsewhere in this codebase. Defaults to a real
  /// `http.Client()`.
  final http.Client? _httpClient;

  /// Overridable geocoder; defaults to the current provider's, built over
  /// [httpClient].
  final PlaceSearch? placeSearch;

  @override
  State<AndroidMapLocationStep> createState() => _AndroidMapLocationStepState();
}

/// Colombo Fort — a sane default center for the invite-only Colombo pilot
/// (ADR-005) before the map has a real signal (search, current location).
const _defaultCenter = LatLng(6.9271, 79.8612);

class _AndroidMapLocationStepState extends State<AndroidMapLocationStep> {
  late final http.Client _httpClient = widget._httpClient ?? http.Client();
  late final PlaceSearch _search =
      widget.placeSearch ?? placeSearchFor(_httpClient);
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
  List<PlaceResult> _results = [];
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
  // The label of the place last chosen (suggestion or direct search). The
  // IME can re-deliver that exact text a moment after it was set (an
  // autocorrect composing pass, a suggestion-strip commit), which the
  // one-shot flag above has already spent, and the step then searched for
  // the place it had just picked and reopened the dropdown over the map.
  // Text identical to the chosen label is not a new query.
  String? _lastChosenLabel;
  // ADR-029 (round-8 hardening) — set when the user taps "use my current
  // location" and a position is resolved. _useCurrentLocation no longer
  // fills the search field with a hardcoded "Current location" placeholder
  // (that string used to be submitted verbatim as location_label to
  // everyone, forever — fixed by submitting an empty label instead and
  // letting the server reverse-geocode it), so _canContinue needs this
  // separate signal to unlock CONTINUE even while the field stays empty.
  bool _locationPicked = false;
  // A fix is being fetched: the button shows it and ignores taps.
  bool _locating = false;

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
    if (_searchController.text == _lastChosenLabel) return;
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
    // One character cannot rank anything useful and the geocoder is a
    // shared, fair-use service; nothing is sent until there are two.
    if (text.trim().length < 2) {
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
      final results = await _search.suggest(
        text,
        focusLat: focus.latitude,
        focusLng: focus.longitude,
      );
      if (generation != _requestGeneration || !mounted) return;
      setState(() => _results = results);
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

  Future<void> _selectResult(PlaceResult result) async {
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
    final target = LatLng(result.latitude, result.longitude);
    _lastChosenLabel = result.label;
    setState(() {
      _searchController.text = result.label;
      _results = [];
      _pickedLocation = target;
    });
    await _controller?.animateCamera(CameraUpdate.newLatLngZoom(target, 15));
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
      final result = await _search.search(
        text,
        focusLat: focus.latitude,
        focusLng: focus.longitude,
      );
      if (generation != _requestGeneration || !mounted) return;
      if (result == null) {
        _showError('No results for "$text".');
        return;
      }
      final target = LatLng(result.latitude, result.longitude);
      _lastChosenLabel = result.label;
      _suppressNextSearch = true;
      setState(() {
        _searchController.text = result.label;
        _pickedLocation = target;
      });
      await _controller?.animateCamera(CameraUpdate.newLatLngZoom(target, 15));
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
    if (_locating) return;
    setState(() => _locating = true);
    try {
      // Permission prompt, deadline, last-known fallback and the settings
      // shortcut all live in resolveCurrentLocationForMap, shared with the
      // iOS step.
      final position = await resolveCurrentLocationForMap(context);
      if (!mounted || position == null) return;
      final here = LatLng(position.latitude, position.longitude);
      setState(() => _pickedLocation = here);
      await _controller?.animateCamera(CameraUpdate.newLatLngZoom(here, 15));
      // Leave the search field as-is (ADR-029) — no placeholder text is
      // submitted; the server resolves a real label from the coordinates
      // if the field stays empty. _locationPicked is what unlocks CONTINUE
      // in that case.
      if (mounted) setState(() => _locationPicked = true);
    } finally {
      if (mounted) setState(() => _locating = false);
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
    if (!MapConfig.isConfigured) {
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
                PlaceSearchBar(
                  controller: _searchController,
                  hint: 'Search for a cafe, restaurant, or venue',
                  busy: _searching,
                  onSubmitted: _directSearch,
                  onCleared: () => setState(() => _results = []),
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
                          styleString: MapConfig.styleUrl(),
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
                            color: MapConfig.pinColor,
                            size: 36,
                            shadows: [
                              Shadow(
                                color: Colors.black.withValues(alpha: 0.45),
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
                UseCurrentLocationButton(
                  onPressed: _useCurrentLocation,
                  busy: _locating,
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
            // search-then-pick overlay. Starts at the search bar's
            // own height, not Positioned.fill — covering the
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
            // the top offset above.
            if (_results.isNotEmpty)
              Positioned(
                top: PlaceSearchBar.height,
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
            if (_results.isNotEmpty)
              Positioned(
                top: PlaceSearchBar.height + 6,
                left: 0,
                right: 0,
                child: PlaceSuggestionsDropdown(
                  suggestions: [
                    for (final r in _results)
                      PlaceSuggestion.fromLabel(r.label),
                  ],
                  onSelect: (index) => _selectResult(_results[index]),
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
            'The map isn\'t configured for this build: it was built for '
            'Stadia Maps without an access key. Build with MAP_PROVIDER=osm '
            'or provide the key.',
            style: TextStyle(color: AppPalette.danger, fontSize: 12),
          ),
        ),
      ],
    );
  }
}
