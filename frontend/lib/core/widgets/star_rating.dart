import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// Compact read-only display of a user's post-meetup star rating aggregate
/// (ADR-015, docs/02-domain/domain-model.md § Rating) — a single filled
/// star icon plus the numeric average, or "New" when [count] is 0 (nobody's
/// rated this person yet, so a "0.0" would misleadingly read as a bad
/// score rather than no data).
class StarRating extends StatelessWidget {
  const StarRating({
    super.key,
    required this.average,
    required this.count,
    this.size = 12,
  });

  final double average;
  final int count;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.star_rounded, size: size, color: AppPalette.gold),
        const SizedBox(width: 3),
        Text(
          count == 0 ? 'New' : average.toStringAsFixed(1),
          style: TextStyle(
            fontSize: size,
            fontWeight: FontWeight.w700,
            color: AppPalette.textSecondary,
          ),
        ),
      ],
    );
  }
}
