import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// One intent on the Schedule flow's "What kind of meetup?" step: a scene
/// from the landing collage as backdrop, a scrim so type stays legible over
/// any of those images, the intent's icon in a chip, its name, and a
/// one-line tagline. Same corner radius and hairline as the meetup cards,
/// so the picker reads as part of the same system rather than a different
/// app.
///
/// Locked intents stay visible: the image is desaturated and dimmed, a
/// lock replaces the icon chip, and the required level is named on the
/// card — the point of showing a lock is telling the user what would open
/// it, and the tap still routes to the unlock page (schedule_flow.dart).
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

  static const _radius = 14.0;

  @override
  Widget build(BuildContext context) {
    final accent = AppPalette.brandGreen;
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
                borderRadius: BorderRadius.circular(_radius),
                border: Border.all(
                  color: selected ? accent : AppPalette.hairline,
                  width: selected ? 2 : 1,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_radius - 1),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Locked → greyscale via a saturation-zero matrix, then
                    // dimmed by the scrim below. Colour filter on the image
                    // alone, not the text, so the lock copy stays crisp.
                    ColorFiltered(
                      colorFilter: locked
                          ? const ColorFilter.matrix(<double>[
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
                            ])
                          : const ColorFilter.mode(
                              Colors.transparent,
                              BlendMode.dst,
                            ),
                      child: Image.asset(
                        intent.imageAsset,
                        fit: BoxFit.cover,
                        cacheWidth: cacheWidth > 0 ? cacheWidth : null,
                        excludeFromSemantics: true,
                        errorBuilder: (_, _, _) =>
                            ColoredBox(color: AppPalette.card),
                      ),
                    ),
                    // Scrim: the scene stays clear over the top ~45%, then
                    // shades firmly toward the bottom so the icon and type
                    // sit on a dark ground rather than on whatever the
                    // picture happens to be there. Locked cards are dimmed
                    // throughout. Always dark regardless of theme — the
                    // text over it is always light.
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: locked ? 0.55 : 0.0),
                            Colors.black.withValues(
                              alpha: locked ? 0.70 : 0.35,
                            ),
                            Colors.black.withValues(
                              alpha: locked ? 0.88 : 0.86,
                            ),
                          ],
                          stops: const [0.30, 0.55, 1.0],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Align(
                            alignment: Alignment.topRight,
                            child: locked
                                ? _LockPill(
                                    text: intent.hostingDeferred
                                        ? 'COMING SOON'
                                        : 'LEVEL ${intent.requiredTrustLevelToHost}',
                                  )
                                : selected
                                ? Icon(
                                    Icons.check_circle_rounded,
                                    size: 20,
                                    color: accent,
                                  )
                                : const SizedBox(height: 20),
                          ),
                          const Spacer(),
                          Row(
                            children: [
                              _IconChip(
                                icon: locked ? Icons.lock_outline : intent.icon,
                                locked: locked,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  intent.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.2,
                                    height: 1.1,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            intent.tagline,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.80),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                              height: 1.25,
                            ),
                          ),
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

class _IconChip extends StatelessWidget {
  const _IconChip({required this.icon, required this.locked});

  final IconData icon;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
      ),
      child: Icon(
        icon,
        size: 16,
        color: Colors.white.withValues(alpha: locked ? 0.7 : 1.0),
      ),
    );
  }
}

class _LockPill extends StatelessWidget {
  const _LockPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.85),
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}
