import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';

/// One intent on the Schedule flow's "What kind of meetup?" step: the
/// scene photo on top, the intent's name on the card surface under it.
///
/// # THE NAME CAME OUT FROM ON TOP OF THE PHOTO
///
/// This used to lay the icon and the name over the image, with a scrim to
/// keep them legible. The scrim had to be heavy — 86% black at the
/// bottom — because the assets are bright illustrations, and at that
/// weight the lower third of every picture was a black band. So the tile
/// was paying for a photo it was then hiding, and "Mentorship" over a
/// white whiteboard was still the worst-read label on the screen.
///
/// The screen set puts the name in a row UNDER the picture, which is also
/// what makes it readable without covering anything: image, then label.
/// The photo is now fully visible and the type is on the card surface at
/// full contrast.
///
/// Locked intents stay visible: the image is desaturated, a lock sits in
/// the label row, and the required level is named there — the point of
/// showing a lock is telling the user what would open it, and the tap
/// still routes to the unlock page (schedule_flow.dart).
///
/// The image decodes at the card's own pixel width (cacheWidth), never at
/// the asset's native size — six of these render at once.
class IntentTile extends StatelessWidget {
  const IntentTile({
    super.key,
    required this.intent,
    required this.selected,
    required this.locked,
    required this.onTap,
  });

  final IntentType intent;
  final bool selected;
  final bool locked;
  final VoidCallback onTap;

  static const _radius = 18.0;

  /// Greyscale, for a locked intent. Luminance weights, so the result
  /// reads as a dimmed photograph rather than a flat average.
  static const List<double> _grey = <double>[
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ];

  @override
  Widget build(BuildContext context) {
    final accent = AppPalette.brandGreen;

    // The note on the right of the label row: what is stopping this one
    // being picked, or nothing at all.
    final String? note = !locked
        ? null
        : intent.hostingDeferred
        ? 'Coming soon'
        : 'Level ${intent.requiredTrustLevelToHost}';

    return Semantics(
      button: true,
      selected: selected,
      label: locked
          ? (intent.hostingDeferred
                ? '${intent.label}, coming soon'
                : '${intent.label}, locked, requires level '
                      '${intent.requiredTrustLevelToHost}')
          : intent.label,
      child: GestureDetector(
        onTap: onTap,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final dpr = MediaQuery.devicePixelRatioOf(context);
            final cacheWidth = (constraints.maxWidth * dpr).round();
            return AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                color: AppPalette.card,
                borderRadius: BorderRadius.circular(_radius),
                border: Border.all(
                  color: selected ? accent : AppPalette.hairline,
                  width: selected ? 2 : 1,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_radius - 1),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Expanded, not a fixed aspect ratio: the GRID sets
                    // the cell height (childAspectRatio in schedule_flow),
                    // so the picture takes whatever is left after the
                    // label row. Claiming a ratio of its own overflowed
                    // every tile by a couple of pixels.
                    Expanded(
                      child: ColorFiltered(
                        colorFilter: locked
                            ? const ColorFilter.matrix(_grey)
                            : const ColorFilter.mode(
                                Colors.transparent,
                                BlendMode.dst,
                              ),
                        child: Opacity(
                          opacity: locked ? 0.55 : 1,
                          child: Image.asset(
                            intent.imageAsset,
                            fit: BoxFit.cover,
                            cacheWidth: cacheWidth > 0 ? cacheWidth : null,
                            excludeFromSemantics: true,
                            errorBuilder: (_, _, _) =>
                                ColoredBox(color: AppPalette.raised),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(11, 9, 11, 10),
                      child: Row(
                        children: [
                          // No lock glyph. The screen set's locked tile is
                          // the dimmed photo and the reason, nothing else —
                          // and on a half-width card the glyph was taking
                          // the room that turned "Ride share" into
                          // "Ride sh…". The greyed picture already says
                          // this one is not available; the note says why.
                          if (selected) ...[
                            AppIcon(
                              AppIcons.checkCircle,
                              size: 14,
                              color: accent,
                            ),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              intent.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: locked
                                    ? AppPalette.textSecondary
                                    : AppPalette.textPrimary,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (note != null) ...[
                            const SizedBox(width: 6),
                            Text(
                              note,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppPalette.textTertiary,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
