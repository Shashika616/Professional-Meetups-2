import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/maps/map_canvas.dart';
import 'package:professional_connections_platform/core/maps/map_sheet_scaffold.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/meetups/widgets/place_search_ui.dart';
import 'package:professional_connections_platform/features/meetups/widgets/selected_place_banner.dart';

/// Everything both location pickers draw, once.
///
/// # WHY THIS IS ONE WIDGET AND NOT TWO BUILD METHODS
///
/// iOS and Android differ in exactly two things: which SDK renders the map,
/// and which service answers a search. Everything else — where the search
/// field floats, how the suggestions cover the map, what the panel says,
/// which button is disabled until a place is chosen — is the same product,
/// and it was written out twice. The two copies had already drifted in the
/// details, and every fix to the dropdown's paint order had to be made
/// twice and explained twice.
///
/// So the platform files now own only their state machine (debounce,
/// request generations, whichever search backend they talk to) and hand
/// the finished values here. A third platform, or a swapped provider,
/// writes a [MapCanvas] and a search backend and gets this screen for
/// free.
///
/// # THE SHAPE
///
/// The map is the page. A search field floats over the top of it, and a
/// panel rests on the bottom edge carrying what was chosen and what to do
/// next — the arrangement Uber, PickMe and every ride app settled on,
/// because the map needs the room and the decision needs to be where the
/// thumb already is. [MapSheetScaffold] does the geometry, including
/// keeping the pin centred in the part of the map the panel does not
/// cover.
class LocationPickerLayout extends StatelessWidget {
  const LocationPickerLayout({
    super.key,
    required this.map,
    required this.searchController,
    required this.searching,
    required this.suggestions,
    required this.selectedLabel,
    required this.canContinue,
    required this.locating,
    required this.onSubmitted,
    required this.onCleared,
    required this.onSelectSuggestion,
    required this.onDismissSuggestions,
    required this.onUseCurrentLocation,
    required this.onContinue,
  });

  /// The platform's map surface, already configured. Built by the caller
  /// so it can hold the controller and the camera callbacks.
  final Widget map;

  final TextEditingController searchController;
  final bool searching;

  /// Empty hides the dropdown and its scrim entirely.
  final List<PlaceSuggestion> suggestions;

  /// What CONTINUE will submit as the label. Empty means the place came
  /// from the device's own position, which the panel says out loud rather
  /// than showing a blank (ADR-029: the server reverse-geocodes it).
  final String selectedLabel;

  final bool canContinue;
  final bool locating;

  final ValueChanged<String> onSubmitted;
  final VoidCallback onCleared;
  final void Function(int index) onSelectSuggestion;
  final VoidCallback onDismissSuggestions;
  final VoidCallback onUseCurrentLocation;
  final VoidCallback onContinue;

  /// Where the suggestions list starts: under the floating field, which
  /// [MapSheetScaffold] insets by 12 from the top of the visible map.
  static const _searchTop = 12.0;
  static const _sideInset = 16.0;

  @override
  Widget build(BuildContext context) {
    final showSuggestions = suggestions.isNotEmpty;
    return MapSheetScaffold(
      map: map,
      // Lifted while the dropdown is open, so the pin reads as parked
      // rather than as tracking a map the user cannot currently drag.
      centrePin: MapCentrePin(lifted: showSuggestions),
      topOverlay: SafeArea(
        bottom: false,
        child: PlaceSearchBar(
          controller: searchController,
          hint: 'Search for a cafe, restaurant, or venue',
          busy: searching,
          onSubmitted: onSubmitted,
          onCleared: onCleared,
        ),
      ),
      sheet: _PickerSheet(
        selectedLabel: selectedLabel,
        canContinue: canContinue,
        locating: locating,
        onUseCurrentLocation: onUseCurrentLocation,
        onContinue: onContinue,
      ),
      overlay: showSuggestions
          ? _SuggestionsOverlay(
              suggestions: suggestions,
              onSelect: onSelectSuggestion,
              onDismiss: onDismissSuggestions,
              top:
                  _searchTop +
                  PlaceSearchBar.height +
                  MediaQuery.paddingOf(context).top,
              sideInset: _sideInset,
            )
          : null,
    );
  }
}

/// The panel: what was chosen, how to choose the device's position, and
/// the way forward.
class _PickerSheet extends StatelessWidget {
  const _PickerSheet({
    required this.selectedLabel,
    required this.canContinue,
    required this.locating,
    required this.onUseCurrentLocation,
    required this.onContinue,
  });

  final String selectedLabel;
  final bool canContinue;
  final bool locating;
  final VoidCallback onUseCurrentLocation;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return MapSheet(
      children: [
        Text(
          'Where?',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: AppPalette.textPrimary,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 6),
        // Choose a public place — never a stranger's home address (Safety
        // UX Flows.md's pre-meetup safety copy, ADR-013 §4). It stays on
        // the screen rather than behind an info icon: it is the one line
        // here that exists for someone's safety, and the panel is where
        // the eye already is.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.shield_outlined,
              size: 14,
              color: AppPalette.textSecondary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Choose a public place: A cafe, restaurant, or well-known '
                'venue, not a private residence.',
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        // What CONTINUE will submit, said out loud. Held in a fixed-height
        // slot so the panel does not jump — and therefore the map does not
        // resize — the moment a place is chosen.
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: canContinue
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SelectedPlaceBanner(label: selectedLabel),
                )
              : const SizedBox(width: double.infinity),
        ),
        UseCurrentLocationButton(
          onPressed: onUseCurrentLocation,
          busy: locating,
        ),
        const SizedBox(height: 12),
        PrimaryButton(
          label: 'CONTINUE',
          onPressed: canContinue ? onContinue : null,
        ),
      ],
    );
  }
}

/// The suggestions list, and the scrim that makes it the only thing on
/// screen worth touching.
///
/// # WHY A SCRIM AT ALL
///
/// This list has to cover both the map and the panel, and nothing behind
/// it may stay tappable — a CONTINUE you can hit through an open dropdown
/// submits whatever the map happened to be centred on. Dimming also stops
/// the map's own detail reading through a list of place names.
///
/// The ClipRect is load-bearing, not decorative: a BackdropFilter is not
/// clipped to its own bounds by default, so its blur samples and paints
/// across the whole layer behind it — the reason an earlier version of
/// this bled upward over the search field and made the text being typed
/// unreadable. Clipping it to the scrim's own rectangle is what keeps the
/// field crisp while everything under it is dimmed.
class _SuggestionsOverlay extends StatelessWidget {
  const _SuggestionsOverlay({
    required this.suggestions,
    required this.onSelect,
    required this.onDismiss,
    required this.top,
    required this.sideInset,
  });

  final List<PlaceSuggestion> suggestions;
  final void Function(int index) onSelect;
  final VoidCallback onDismiss;
  final double top;
  final double sideInset;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: top,
          left: 0,
          right: 0,
          bottom: 0,
          child: ClipRect(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onDismiss,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: ColoredBox(
                  color: AppPalette.onyx.withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: top + 6,
          left: sideInset,
          right: sideInset,
          child: PlaceSuggestionsDropdown(
            suggestions: suggestions,
            onSelect: onSelect,
          ),
        ),
      ],
    );
  }
}
