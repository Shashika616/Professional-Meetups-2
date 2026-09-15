import 'dart:async';
import 'dart:ui';

import 'package:apple_maps_flutter/apple_maps_flutter.dart';
import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/meetups/widgets/place_search_ui.dart';
import 'package:professional_connections_platform/core/widgets/step_hero.dart';
import 'package:professional_connections_platform/features/meetups/widgets/selected_place_banner.dart';
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
const _defaultCenter = LatLng(6.9271, 79.8612);

class _IosMapLocationStepState extends State<IosMapLocationStep> {
  static const _search = IosLocalSearch();

  AppleMapController? _controller;
  LatLng _cameraTarget = _defaultCenter;
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
        lat: _cameraTarget.latitude,
        lon: _cameraTarget.longitude,
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
        lat: _cameraTarget.latitude,
        lon: _cameraTarget.longitude,
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
    final target = LatLng(lat, lon);
    setState(() => _cameraTarget = target);
    await _controller?.animateCamera(CameraUpdate.newLatLngZoom(target, 15));
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
      _cameraTarget.latitude,
      _cameraTarget.longitude,
      _searchController.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepTitle(),
        // Same banner as the Android step — the provider differs, the
        // page's look must not. Slim, since the map is the real picture.
        const StepHero(
          asset: 'assets/images/schedule/location_card.jpg',
          height: 96,
        ),
        const SizedBox(height: 14),
        // Choose a public place — never a stranger's home address
        // (Safety UX Flows.md's pre-meetup safety copy, ADR-013 § 4). Same
        // copy as the Android implementation — this requirement doesn't
        // change with the provider.
        Text(
          'Choose a public place: A cafe, restaurant, or well-known '
          'venue, not a private residence.',
          style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: 16),
        Stack(
          // clipBehavior: Clip.none (not the Stack default, Clip.hardEdge)
          // is only half of it — see AndroidMapLocationStep's own doc
          // comment on this bug (same fix applies here: the search field
          // and the map share this one outer Stack as a single Column, so
          // the dropdown — a later Stack child — reliably paints *above*
          // the map too, not just above the search field).
          clipBehavior: Clip.none,
          children: [
            Column(
              children: [
                PlaceSearchBar(
                  controller: _searchController,
                  hint: 'Search for a cafe, restaurant, or venue',
                  busy: _searching,
                  onSubmitted: _directSearch,
                  onCleared: () => setState(() => _completions = []),
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: SizedBox(
                    height: 240,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        AppleMap(
                          initialCameraPosition: const CameraPosition(
                            target: _defaultCenter,
                            zoom: 13,
                          ),
                          onMapCreated: (controller) =>
                              _controller = controller,
                          onCameraMove: (position) =>
                              _cameraTarget = position.target,
                        ),
                        // Fixed center crosshair — same "picked location
                        // is wherever the map is centered" pattern as
                        // Android, per the base plan's own call (simpler
                        // and less error-prone than a tap-to-place
                        // gesture).
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
                // What CONTINUE will submit, said out loud — same banner as
                // the Android step (see SelectedPlaceBanner for the
                // current-location wording).
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
            // tappable through the completions list — see
            // AndroidMapLocationStep's matching comment for why (paint
            // order: these are earlier Column siblings, so without this
            // scrim CONTINUE rendered visually *over* an overflowing
            // dropdown, not under it). Tapping the scrim dismisses the
            // dropdown without picking a completion. Starts at the search bar's height
            // (the search field's own height), not Positioned.fill —
            // covering the field too blurred/darkened the text being
            // typed, making it unreadable while the dropdown was open.
            //
            // The ClipRect here is load-bearing, not decorative:
            // BackdropFilter is NOT clipped to its own widget bounds by
            // default — its blur samples/paints across the whole layer
            // behind it (worse still since this Stack is Clip.none), so
            // without this it bled upward into the search field, the step
            // title, and the header above this widget entirely, which is
            // exactly why the field stayed unreadable even after adding
            // the top offset above.
            if (_completions.isNotEmpty)
              Positioned(
                top: PlaceSearchBar.height,
                left: 0,
                right: 0,
                bottom: 0,
                child: ClipRect(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _completions = []),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                      child: Container(
                        color: AppPalette.onyx.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ),
              ),
            if (_completions.isNotEmpty)
              Positioned(
                top: PlaceSearchBar.height + 6,
                left: 0,
                right: 0,
                child: PlaceSuggestionsDropdown(
                  suggestions: [
                    for (final c in _completions)
                      PlaceSuggestion(title: c.title, subtitle: c.subtitle),
                  ],
                  onSelect: _selectCompletion,
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
