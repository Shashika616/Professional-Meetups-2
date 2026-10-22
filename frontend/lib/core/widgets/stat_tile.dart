import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';

/// One cell of the stat strip under a profile header: a big value over a
/// small caption ("12 / Meetups", "4.8 / Rating", "L3 / Trust level").
///
/// # THE VALUE IS A [FittedBox], AND THAT IS LOAD-BEARING
///
/// These are laid out as equal-width columns, so the widest value decides
/// nothing — each cell gets exactly one third of the row no matter what is
/// in it. "No ratings yet" has to survive in the same box that usually
/// holds "4.8". Scaling down beats ellipsizing ("No rating…" is worse than
/// small) and beats wrapping (which would make one of the three cells
/// taller than its neighbours).
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return FlatCard(
      radius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 11),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 24,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 17,
                  height: 1.1,
                  letterSpacing: -0.3,
                  fontWeight: FontWeight.w700,
                  color: AppPalette.textPrimary,
                  // Keeps a column of numbers from jittering as it
                  // updates — these are counts and averages, and
                  // proportional digits make "11" narrower than "48".
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 10.5,
              height: 1.2,
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// The three-up row [StatTile] is designed for.
class StatTileRow extends StatelessWidget {
  const StatTileRow({super.key, required this.tiles});

  final List<StatTile> tiles;

  @override
  Widget build(BuildContext context) {
    // IntrinsicHeight, NOT a bare `crossAxisAlignment: stretch`.
    //
    // Stretch asks each child to fill the row's height, and a Row inside a
    // scrollable has no height to give — it reports `h=Infinity`, the
    // children fail layout, and the ENTIRE sliver renders blank. (Not the
    // row: the whole list. That is how this shipped as "the page is
    // empty" rather than as "the stats look wrong".)
    //
    // IntrinsicHeight measures the tallest tile first and gives the row
    // that height, so the three cells still match without anyone needing
    // an unbounded constraint. It costs an extra layout pass over three
    // small children, once.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(child: tiles[i]),
          ],
        ],
      ),
    );
  }
}
