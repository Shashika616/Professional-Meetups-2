import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';

class SafetyTipCard extends StatelessWidget {
  const SafetyTipCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: FlatCard(
        radius: 12,
        tint: AppPalette.verified.withValues(alpha: 0.06),
        border: AppPalette.verified.withValues(alpha: 0.25),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.shield_outlined, color: AppPalette.verified, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Safety tip: always meet in public places for the first time and share your live location with a trusted contact.',
                style: TextStyle(
                  color: AppPalette.textSecondary.withValues(alpha: 0.9),
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
