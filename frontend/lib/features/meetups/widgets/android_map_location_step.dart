// ignore_for_file: prefer_initializing_formals
// AndroidMapLocationStep's public `httpClient` param name deliberately
// differs from the private `_httpClient` field it initializes — same
// tradeoff as token_refresher.dart's own doc comment on this lint.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/maps/map_provider.dart';
import 'package:professional_connections_platform/core/maps/map_canvas.dart';
import 'package:professional_connections_platform/core/maps/place_search.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/features/meetups/widgets/location_picker_layout.dart';
import 'package:professional_connections_platform/features/meetups/widgets/place_search_ui.dart';

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
const _defaultCenter = MapPoint(6.9271, 79.8612);

class _AndroidMapLocationStepState extends State<AndroidMapLocationStep> {
  late final http.Client _httpClient = widget._httpClient ?? http.Client();
  late final PlaceSearch _search =
      widget.placeSearch ?? placeSearchFor(_httpClient);
  MapCanvasController? _canvas;
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
  MapPoint _pickedLocation = _defaultCenter;
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
        focusLat: focus.lat,
        focusLng: focus.lng,
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
    final target = MapPoint(result.latitude, result.longitude);
    _lastChosenLabel = result.label;
    setState(() {
      _searchController.text = result.label;
      _results = [];
      _pickedLocation = target;
    });
    await _canvas?.moveTo(target, zoom: 15);
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
        focusLat: focus.lat,
        focusLng: focus.lng,
      );
      if (generation != _requestGeneration || !mounted) return;
      if (result == null) {
        _showError('No results for "$text".');
        return;
      }
      final target = MapPoint(result.latitude, result.longitude);
      _lastChosenLabel = result.label;
      _suppressNextSearch = true;
      setState(() {
        _searchController.text = result.label;
        _pickedLocation = target;
      });
      await _canvas?.moveTo(target, zoom: 15);
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
      final here = MapPoint(position.latitude, position.longitude);
      setState(() => _pickedLocation = here);
      await _canvas?.moveTo(here, zoom: 15);
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
    showSnack(context, message, type: ToastType.warning);
  }

  bool get _canContinue =>
      _searchController.text.trim().isNotEmpty || _locationPicked;

  void _submit() {
    widget.onSubmit(
      _pickedLocation.lat,
      _pickedLocation.lng,
      _searchController.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!MapConfig.isConfigured) {
      return const _NotConfiguredNotice();
    }

    return LocationPickerLayout(
      // MapLibre against whichever tiles MapConfig selected — the only
      // thing this file still says about rendering.
      map: MapCanvas(
        initialCentre: _defaultCenter,
        initialZoom: 13,
        onReady: (canvas) => _canvas = canvas,
        // Keeps the picked point in step with a map the user dragged by
        // hand. Search and current-location set it directly and
        // synchronously (see their own comments), so this matters for the
        // "no search, just move the map" path.
        onCameraMove: (point) => _pickedLocation = point,
      ),
      searchController: _searchController,
      searching: _searching,
      suggestions: [
        for (final r in _results) PlaceSuggestion.fromLabel(r.label),
      ],
      selectedLabel: _searchController.text.trim(),
      canContinue: _canContinue,
      locating: _locating,
      onSubmitted: _directSearch,
      onCleared: () => setState(() => _results = []),
      // The layout speaks in list positions (it never sees a PlaceResult);
      // this side owns the objects behind them.
      onSelectSuggestion: (index) => _selectResult(_results[index]),
      onDismissSuggestions: () => setState(() => _results = []),
      onUseCurrentLocation: _useCurrentLocation,
      onContinue: _submit,
    );
  }
}

/// Shown in place of the map when the build selected Stadia without a
/// key. No step title of its own any more: the flow's header carries it,
/// and this branch is not a map screen.
class _NotConfiguredNotice extends StatelessWidget {
  const _NotConfiguredNotice();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
