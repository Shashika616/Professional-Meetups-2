import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';

/// The chosen place, read back under the map. Green edge to match the
/// timing step's window summary — the same "this is what you are about to
/// create" affordance on each step.
class SelectedPlaceBanner extends StatelessWidget {
  const SelectedPlaceBanner({super.key, required this.label});

  /// Empty when the place came from "use my current location" (ADR-029:
  /// the server resolves the address from the coordinates).
  final String label;

  @override
  Widget build(BuildContext context) {
    final fromDevice = label.isEmpty;
    // No coloured rule down the left edge, and an opaque tint rather
    // than a translucent one — the same two corrections every other
    // card in the app got. The leading check already carries the green.
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppPalette.tintedSurface(
            AppPalette.brandGreen.withValues(alpha: 0.10),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppIcon(
                fromDevice ? AppIcons.locate : AppIcons.pin,
                size: 16,
                color: AppPalette.brandGreen,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fromDevice ? 'Your current location' : label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      fromDevice
                          ? 'Pinned on the map. The street address is '
                                'filled in when you schedule.'
                          : 'Drag the map to fine-tune the pin.',
                      style: TextStyle(
                        color: AppPalette.textSecondary,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
