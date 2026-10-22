import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/location.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
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
        icon: AppIcon(
          AppIcons.xCircle,
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
          AppIcon(AppIcons.search, size: 20, color: accent),
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
///
/// # IT OPENS BEFORE THERE IS ANYTHING IN IT
///
/// This used to exist only once results had arrived. The geocoders behind
/// it take seconds to answer — four and more, measured against the live
/// service — so typing produced an empty map and no sign that anything
/// was happening, and a search that genuinely matched nothing was
/// indistinguishable from a search that was still running, or from a
/// field that had not registered the keystrokes at all. The panel now
/// opens as soon as there is a query to answer and says which of the
/// three it is.
class PlaceSuggestionsDropdown extends StatelessWidget {
  const PlaceSuggestionsDropdown({
    super.key,
    required this.suggestions,
    required this.onSelect,
    this.searching = false,
  });

  final List<PlaceSuggestion> suggestions;
  final void Function(int index) onSelect;

  /// A lookup is in flight. With results already on screen they stay
  /// there under a thin progress line, so the list does not blank out
  /// between keystrokes; with none, the panel says it is looking.
  final bool searching;

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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A 2px line along the top edge while a lookup runs: visible
          // whether or not the list under it has anything in it yet, and
          // it costs no height when it is gone.
          SizedBox(
            height: 2,
            child: searching
                ? LinearProgressIndicator(
                    minHeight: 2,
                    color: AppPalette.candyBlue,
                    backgroundColor: AppPalette.candyBlue.withValues(
                      alpha: 0.15,
                    ),
                  )
                : null,
          ),
          if (suggestions.isEmpty)
            _StatusRow(
              searching ? 'Looking for places…' : 'No places found',
              hint: searching
                  ? null
                  : 'Try a venue name, a street, or an area.',
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(
                maxHeight: _maxVisibleRows * _rowHeight,
              ),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 6),
                shrinkWrap: true,
                itemCount: suggestions.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, indent: 60, color: AppPalette.hairline),
                itemBuilder: (context, index) => _SuggestionRow(
                  suggestions[index],
                  onTap: () => onSelect(index),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The panel with no rows in it: looking, or nothing found.
class _StatusRow extends StatelessWidget {
  const _StatusRow(this.title, {this.hint});

  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Row(
        children: [
          AppIcon(AppIcons.search, size: 17, color: AppPalette.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (hint != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    hint!,
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
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
        child: AppIcon(AppIcons.pin, size: 17, color: accent),
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
    if (busy) return const _FindingYouButton();
    return SecondaryButton(
      label: 'Use my current location',
      icon: AppIcons.locate,
      height: 44,
      color: AppPalette.candyBlue,
      borderColor: AppPalette.candyBlue.withValues(alpha: 0.6),
      onPressed: onPressed,
    );
  }
}

/// The button while a fix is in flight. A label swap alone read as a
/// frozen button for the ten-odd seconds a fix can take indoors, so this
/// keeps moving the whole time: a ring sweeps around the crosshair and the
/// label breathes. Same size and border as the idle button so nothing
/// jumps when it swaps in; disabled, since a second tap would only start a
/// second read.
class _FindingYouButton extends StatefulWidget {
  const _FindingYouButton();

  @override
  State<_FindingYouButton> createState() => _FindingYouButtonState();
}

class _FindingYouButtonState extends State<_FindingYouButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = AppPalette.candyBlue;
    return OutlinedButton(
      key: const Key('findingYouButton'),
      onPressed: null,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(44),
        side: BorderSide(color: color.withValues(alpha: 0.6)),
      ),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          // Ease in and out of full strength so the text reads as breathing
          // rather than blinking.
          final breath = 0.55 + 0.45 * (0.5 - 0.5 * math.cos(t * 2 * math.pi));
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Transform.rotate(
                      angle: t * 2 * math.pi,
                      child: CircularProgressIndicator(
                        value: 0.28,
                        strokeWidth: 2,
                        color: color,
                        backgroundColor: color.withValues(alpha: 0.18),
                      ),
                    ),
                    AppIcon(AppIcons.locate, size: 11, color: color),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Finding you',
                maxLines: 1,
                style: TextStyle(
                  color: color.withValues(alpha: breath),
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  letterSpacing: 0.6,
                ),
              ),
              // Three dots that light up in turn, the oldest "still working"
              // signal there is.
              for (var i = 0; i < 3; i++)
                Text(
                  '.',
                  style: TextStyle(
                    color: color.withValues(
                      alpha: ((t * 3).floor() % 3) >= i ? 1 : 0.25,
                    ),
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                  ),
                ),
            ],
          );
        },
      ),
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
/// second or two. Shorter limits than the helper's defaults: the user is
/// watching a button spin, and past ten-odd seconds a clear "could not"
/// with a settings shortcut beats more spinning.
///
/// A denied permission or a disabled service gets a SETTINGS action on the
/// message, since that is the only fix and it lives outside the app.
Future<Position?> resolveCurrentLocationForMap(BuildContext context) async {
  try {
    return await requestCurrentLocation(
      accuracy: LocationAccuracy.medium,
      timeLimit: const Duration(seconds: 8),
      gpsFallbackLimit: const Duration(seconds: 6),
    );
  } on LocationUnavailableException catch (error) {
    if (!context.mounted) return null;
    final settingsAction = switch (error.reason) {
      LocationUnavailableReason.permissionDenied => SnackBarAction(
        label: 'Settings',
        onPressed: Geolocator.openAppSettings,
      ),
      LocationUnavailableReason.servicesDisabled => SnackBarAction(
        label: 'Settings',
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
