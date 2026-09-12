import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// A wide illustration banner under a wizard step's title — the Schedule
/// flow's location, capacity and review steps each carry one. 3:1, rounded
/// like the cards, hairline-bordered so the artwork's own light ground
/// reads as a deliberate panel on the dark page rather than a hole in it.
/// Decoded at the banner's pixel width, not the asset's.
class StepHero extends StatelessWidget {
  const StepHero({super.key, required this.asset, this.height = 116});

  final String asset;
  final double height;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final cacheWidth = constraints.maxWidth.isFinite
            ? (constraints.maxWidth * dpr).round()
            : null;
        return Container(
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppPalette.hairline),
          ),
          clipBehavior: Clip.antiAlias,
          child: Image.asset(
            asset,
            fit: BoxFit.cover,
            cacheWidth: cacheWidth,
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => ColoredBox(color: AppPalette.surface),
          ),
        );
      },
    );
  }
}
