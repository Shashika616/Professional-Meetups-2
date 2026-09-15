import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/location.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';

/// The pieces of the map step's place search that are the same on both
/// platforms: the search bar, the suggestions list and the current-location
/// button. The steps keep their own geocoders and state; only the look
/// lives here, so the two screens cannot drift apart again.
///
/// Modelled on what people already know from the maps apps on their phone:
/// a rounded search bar with the glyph on the left and a clear control on
/// the right, suggestions as rows with the place name in weight and the
/// address after it, and a "locate me" action that reads as a button.

/// One row of the suggestions list. [subtitle] is the address part, drawn
/// lighter after the name; empty when the geocoder gave only a name.
class PlaceSuggestion {
  const PlaceSuggestion({required this.title, this.subtitle = ''});

  /// Splits a geocoder's one-line label ("Name, Street, City") into the
  /// name and the rest.
  factory PlaceSuggestion.fromLabel(String label) {
    final cut = label.indexOf(', ');
    if (cut <= 0) return PlaceSuggestion(title: label);
    return PlaceSuggestion(
      title: label.substring(0, cut),
      subtitle: label.substring(cut + 2),
    );
  }

  final String title;
  final String subtitle;
}

/// The search bar. A rounded field on the card surface whose border takes
/// the accent colour while it has focus, so the active state is visible on
/// the map page's busy background; the trailing slot shows a spinner while
/// a lookup runs and a clear control while there is text.
class PlaceSearchBar extends StatefulWidget {
  const PlaceSearchBar({
    super.key,
    required this.controller,
    required this.hint,
    required this.busy,
    this.onSubmitted,
    this.onCleared,
  });

  final TextEditingController controller;
  final String hint;

  /// Whether a lookup is in flight; shows the spinner.
  final bool busy;

  /// The keyboard's search action.
  final ValueChanged<String>? onSubmitted;

  /// Called after the clear control empties the field, so the owner can
  /// drop stale suggestions.
  final VoidCallback? onCleared;

  /// The bar's height, which the owning step positions its dropdown under.
  static const double height = 52;

  @override
  State<PlaceSearchBar> createState() => _PlaceSearchBarState();
}

class _PlaceSearchBarState extends State<PlaceSearchBar> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_rebuild);
    widget.controller.addListener(_rebuild);
  }

  @override
  void didUpdateWidget(PlaceSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_rebuild);
      widget.controller.addListener(_rebuild);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    _focus.removeListener(_rebuild);
    _focus.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _clear() {
    widget.controller.clear();
    widget.onCleared?.call();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    final hasText = widget.controller.text.isNotEmpty;
    final accent = AppPalette.candyBlue;

    Widget trailing;
    if (widget.busy) {
      trailing = SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: accent),
      );
    } else if (hasText) {
      trailing = IconButton(
        key: const Key('placeSearchClear'),
        onPressed: _clear,
        tooltip: 'Clear',
        icon: Icon(
          Icons.cancel_rounded,
          size: 18,
          color: AppPalette.textSecondary,
        ),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      );
    } else {
      trailing = const SizedBox.shrink();
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      height: PlaceSearchBar.height,
      padding: const EdgeInsets.only(left: 14, right: 8),
      decoration: BoxDecoration(
        color: AppPalette.card,
        borderRadius: BorderRadius.circular(PlaceSearchBar.height / 2),
        border: Border.all(
          color: focused ? accent : accent.withValues(alpha: 0.45),
          width: focused ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 20, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              autocorrect: false,
              textInputAction: TextInputAction.search,
              onSubmitted: widget.onSubmitted,
              style: TextStyle(color: AppPalette.textPrimary, fontSize: 15),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: widget.hint,
                hintStyle: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 14,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(width: 32, height: 32, child: Center(child: trailing)),
        ],
      ),
    );
  }
}

/// The suggestions under the search bar. Solid, not translucent: over a map
/// the rows must stay legible whatever terrain is behind them. Capped at
/// about five rows and scrolling within itself beyond that.
class PlaceSuggestionsDropdown extends StatelessWidget {
  const PlaceSuggestionsDropdown({
    super.key,
    required this.suggestions,
    required this.onSelect,
  });

  final List<PlaceSuggestion> suggestions;
  final void Function(int index) onSelect;

  static const _maxVisibleRows = 5;
  static const _rowHeight = 60.0;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppPalette.card,
      elevation: 12,
      shadowColor: Colors.black87,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppPalette.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxHeight: _maxVisibleRows * _rowHeight,
        ),
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 6),
          shrinkWrap: true,
          itemCount: suggestions.length,
          separatorBuilder: (_, _) =>
              Divider(height: 1, indent: 60, color: AppPalette.hairline),
          itemBuilder: (context, index) =>
              _SuggestionRow(suggestions[index], onTap: () => onSelect(index)),
        ),
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow(this.suggestion, {required this.onTap});

  final PlaceSuggestion suggestion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppPalette.candyBlue;
    return ListTile(
      dense: true,
      onTap: onTap,
      minLeadingWidth: 32,
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: accent.withValues(alpha: 0.14),
        ),
        child: Icon(Icons.place_rounded, size: 17, color: accent),
      ),
      // One rich line rather than a title and a subtitle: the name carries
      // the weight, the address follows in the secondary colour, and the
      // row still reads (and is found by tests) as its full label.
      title: Text.rich(
        TextSpan(
          text: suggestion.title,
          style: TextStyle(
            color: AppPalette.textPrimary,
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
          ),
          children: [
            if (suggestion.subtitle.isNotEmpty)
              TextSpan(
                text: ', ${suggestion.subtitle}',
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w400,
                ),
              ),
          ],
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// "Use my current location", styled as the button it is: the accent
/// colour on both the label and the border, so it no longer sits on the
/// page as a line of text with a hairline around it. While [busy] it says
/// so and refuses a second tap: a fix can take several seconds, and a
/// button that looks idle in that time reads as broken.
class UseCurrentLocationButton extends StatelessWidget {
  const UseCurrentLocationButton({
    super.key,
    required this.onPressed,
    this.busy = false,
  });

  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SecondaryButton(
      label: busy ? 'FINDING YOU...' : 'USE MY CURRENT LOCATION',
      icon: busy ? Icons.gps_not_fixed_rounded : Icons.my_location_rounded,
      height: 44,
      color: AppPalette.candyBlue,
      borderColor: AppPalette.candyBlue.withValues(alpha: 0.6),
      onPressed: busy ? null : onPressed,
    );
  }
}

/// The device's position for the map steps, or null after telling the
/// user what stood in the way and how to fix it. Goes through
/// [requestCurrentLocation] so both steps get the same deadline and
/// last-known fallback as Home does (a bare `getCurrentPosition` waits for
/// a fresh fix, which indoors on Android can take tens of seconds or
/// never). Medium accuracy: a pin the user then fine-tunes by dragging
/// does not need a GPS-grade fix, and network positioning answers in a
/// second or two.
///
/// A denied permission or a disabled service gets a SETTINGS action on the
/// message, since that is the only fix and it lives outside the app.
Future<Position?> resolveCurrentLocationForMap(BuildContext context) async {
  try {
    return await requestCurrentLocation(accuracy: LocationAccuracy.medium);
  } on LocationUnavailableException catch (error) {
    if (!context.mounted) return null;
    final settingsAction = switch (error.reason) {
      LocationUnavailableReason.permissionDenied => SnackBarAction(
        label: 'SETTINGS',
        onPressed: Geolocator.openAppSettings,
      ),
      LocationUnavailableReason.servicesDisabled => SnackBarAction(
        label: 'SETTINGS',
        onPressed: Geolocator.openLocationSettings,
      ),
      _ => null,
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.message), action: settingsAction),
    );
    return null;
  }
}
