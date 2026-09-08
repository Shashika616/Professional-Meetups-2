import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';

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

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: FlatCard(
        radius: 10,
        padding: const EdgeInsets.all(14),
        tint: selected ? AppPalette.candyBlue.withValues(alpha: 0.15) : null,
        border: selected ? AppPalette.candyBlue.withValues(alpha: 0.6) : null,
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: selected
                    ? AppPalette.tintedSurface(
                        AppPalette.candyBlue.withValues(alpha: 0.2),
                      )
                    : AppPalette.tintedSurface(
                        AppPalette.textPrimary.withValues(alpha: 0.05),
                      ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                intent.icon,
                size: 20,
                color: locked ? AppPalette.textSecondary : AppPalette.candyBlue,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    intent.label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: locked
                          ? AppPalette.textSecondary
                          : AppPalette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    locked ? 'LOCKED' : (selected ? 'SELECTED' : 'AVAILABLE'),
                    style: TextStyle(
                      fontSize: 8,
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.w700,
                      color: locked
                          ? AppPalette.danger.withValues(alpha: 0.8)
                          : selected
                          ? AppPalette.candyBlue
                          : AppPalette.verified,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_circle, size: 16, color: AppPalette.candyBlue),
          ],
        ),
      ),
    );
  }
}
