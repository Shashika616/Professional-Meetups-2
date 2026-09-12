import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

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
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppPalette.brandGreen.withValues(alpha: 0.08),
          border: Border(
            left: BorderSide(color: AppPalette.brandGreen, width: 3),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                fromDevice ? Icons.my_location_rounded : Icons.place_outlined,
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
