import 'dart:async';

import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/maps/map_canvas.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/features/meetups/widgets/location_picker_layout.dart';
import 'package:professional_connections_platform/features/meetups/widgets/place_search_ui.dart';
import 'package:professional_connections_platform/features/meetups/widgets/ios_local_search.dart';

/// iOS's half of [MapLocationStep]'s platform switch (ADR-013 §4's third
/// correction) — Apple MapKit via `apple_maps_flutter` for rendering, a
/// native `MethodChannel` to `MKLocalSearchCompleter`/`MKLocalSearch` for
/// search (see `ios_local_search.dart` and `ios/Runner/LocalSearchChannel.swift`
/// — `apple_maps_flutter` doesn't expose MapKit's search APIs itself).
/// **No API key, no `AppConfig` entry, no billing setup** — settled as the
/// iOS decision rather than provisional (unlike Android's Stadia choice).
class IosMapLocationStep extends StatefulWidget {
  const IosMapLocationStep({super.key, required this.onSubmit});

  final void Function(double lat, double lng, String label) onSubmit;

  @override
  State<IosMapLocationStep> createState() => _IosMapLocationStepState();
}

/// Colombo Fort — a sane default center for the invite-only Colombo pilot
/// (ADR-005) before the map has a real signal (search, current location).
const _defaultCenter = MapPoint(6.9271, 79.8612);

class _IosMapLocationStepState extends State<IosMapLocationStep> {
  static const _search = IosLocalSearch();

  MapCanvasController? _canvas;
  MapPoint _cameraTarget = _defaultCenter;
  final _searchController = TextEditingController();
  List<IosSearchCompletion> _completions = [];
  bool _searching = false;
  Timer? _debounce;
  int _requestGeneration = 0;
  // Same one-shot suppress-flag pattern as AndroidMapLocationStep — see
  // that file's own comment on this field for why it's needed.
  bool _suppressNextSearch = false;
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
    // change must rebuild — including the programmatic assignment the
    // suppress flag below skips the *search* for.
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
    super.dispose();
  }

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      setState(() => _completions = []);
      return;
    }
    // ~300ms is the usual floor for typeahead debouncing (frontend/
    // meetup-scheduling-PLAN.md's 2026-08-18 platform-split addendum,
    // Step 2) — enough to collapse a burst of keystrokes into one request.
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => _autocomplete(text),
    );
  }

  Future<void> _autocomplete(String text) async {
    final generation = ++_requestGeneration;
    setState(() => _searching = true);
    try {
      final completions = await _search.autocomplete(
        text,
        lat: _cameraTarget.lat,
        lon: _cameraTarget.lng,
      );
      if (generation != _requestGeneration || !mounted) return;
      setState(() => _completions = completions);
    } catch (_) {
      if (generation == _requestGeneration && mounted) {
        setState(() => _completions = []);
      }
    } finally {
      if (generation == _requestGeneration && mounted) {
        setState(() => _searching = false);
      }
    }
  }

  Future<void> _selectCompletion(int index) async {
    _debounce?.cancel();
    // Cancelling the Timer above only stops a debounce that hasn't fired
    // yet — it does nothing for an autocomplete request that already fired
    // and is still in flight (e.g. from a keystroke just before this tap).
    // Without invalidating its generation too, that stale request can
    // resolve after this selection and overwrite _completions, reopening
    // the dropdown right after the user picked an address. _directSearch
    // already does this itself (it starts its own request); this path
    // doesn't start a new request, so it has to bump the generation
    // explicitly instead.
    ++_requestGeneration;
    try {
      final result = await _search.resolveCompletion(index);
      if (!mounted) return;
      _suppressNextSearch = true;
      setState(() {
        _searchController.text = result.label;
        _completions = [];
      });
      await _recenter(result.lat, result.lon);
    } catch (_) {
      _showError('Could not resolve that place. Try again.');
    }
  }

  /// The "type a complete query and press search/return" path — a direct
  /// `MKLocalSearch`, producing the same recenter-and-pin-drop result as
  /// picking a completion, without requiring one to be picked (frontend/
  /// meetup-scheduling-PLAN.md's 2026-08-18 platform-split addendum, Step
  /// 2, point 3).
  Future<void> _directSearch(String text) async {
    if (text.trim().isEmpty) return;
    _debounce?.cancel();
    final generation = ++_requestGeneration;
    setState(() {
      _searching = true;
      _completions = [];
    });
    try {
      final result = await _search.search(
        text,
        lat: _cameraTarget.lat,
        lon: _cameraTarget.lng,
      );
      if (generation != _requestGeneration || !mounted) return;
      _suppressNextSearch = true;
      setState(() => _searchController.text = result.label);
      await _recenter(result.lat, result.lon);
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
      // Android step.
      final position = await resolveCurrentLocationForMap(context);
      if (!mounted || position == null) return;
      await _recenter(position.latitude, position.longitude);
      // Leave the search field as-is (ADR-029) — no placeholder text is
      // submitted; the server resolves a real label from the coordinates
      // if the field stays empty. _locationPicked is what unlocks CONTINUE
      // in that case.
      if (mounted) setState(() => _locationPicked = true);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _recenter(double lat, double lon) async {
    final target = MapPoint(lat, lon);
    setState(() => _cameraTarget = target);
    await _canvas?.moveTo(target, zoom: 15);
  }

  void _showError(String message) {
    if (!mounted) return;
    showSnack(context, message, type: ToastType.warning);
  }

  bool get _canContinue =>
      _searchController.text.trim().isNotEmpty || _locationPicked;

  void _submit() {
    widget.onSubmit(
      _cameraTarget.lat,
      _cameraTarget.lng,
      _searchController.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LocationPickerLayout(
      // Apple Maps on iOS, chosen and settled (no key, no billing) — the
      // only thing this file still says about rendering.
      map: MapCanvas(
        initialCentre: _defaultCenter,
        initialZoom: 13,
        onReady: (canvas) => _canvas = canvas,
        // Kept in a plain field, not state: this fires every camera frame
        // and nothing on screen depends on the live value. It is read on
        // submit, and by the search calls that bias results to what the
        // user is looking at.
        onCameraMove: (point) => _cameraTarget = point,
      ),
      searchController: _searchController,
      searching: _searching,
      suggestions: [
        for (final c in _completions)
          PlaceSuggestion(title: c.title, subtitle: c.subtitle),
      ],
      selectedLabel: _searchController.text.trim(),
      canContinue: _canContinue,
      locating: _locating,
      onSubmitted: _directSearch,
      onCleared: () => setState(() => _completions = []),
      onSelectSuggestion: _selectCompletion,
      onDismissSuggestions: () => setState(() => _completions = []),
      onUseCurrentLocation: _useCurrentLocation,
      onContinue: _submit,
    );
  }
}
