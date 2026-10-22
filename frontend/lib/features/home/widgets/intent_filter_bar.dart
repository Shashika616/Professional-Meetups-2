import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/widgets/app_chip.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';

/// The single-row, horizontally scrollable intent filter on Home.
///
/// # WHAT IT REPLACED
///
/// A two-column grid of large tiles (`IntentGrid`) that took most of the
/// first screen, plus a "MORE" overflow sheet (`IntentPickerSheet`) for the
/// intents that did not fit. With six intents plus "All", every option fits
/// in one scrollable row, so both the grid and the overflow sheet are gone —
/// the row IS the complete list, and an overflow affordance for a list with
/// no overflow is just another thing to tap.
///
/// # THEY ARE PILLS AGAIN (2026-10 redesign)
///
/// These were pills, then became text tabs with an underline, on the
/// reasoning that "the words are navigation, not buttons, so they carry no
/// box of their own". That holds on a page whose content is a plain list.
/// It stopped holding here: Home's cards now carry tags that are
/// themselves small tinted pills, so an underlined word above a row of
/// pills read as a different KIND of control than the one it filters, and
/// the selected state — a 3px bar under one word — was the least visible
/// thing in a screen full of surfaces.
///
/// Pills put the filter in the same visual language as the content, and
/// the selected one is a filled shape rather than a line.
///
/// # "ALL" IS A REAL OPTION, NOT AN ABSENCE
///
/// [selected] null means every intent, and the "All" chip is selected in that
/// state rather than nothing being selected. It maps to a nil intent on the
/// backend filter, which is a genuinely different query — not a client-side
/// union of six others.
///
/// # LOCKED INTENTS STAY VISIBLE
///
/// An intent the viewer cannot JOIN is shown dimmed with a lock, never
/// hidden — same rule the grid had. Hiding it would leave a user unable to
/// discover that the thing exists or what unlocks it. Tapping one is the
/// caller's business ([onSelect] is still called); Home explains the gate.
///
/// The lock reflects the JOIN bar specifically: this filter chooses what to
/// BROWSE, and browsing is the join-side question. Hosting has its own,
/// higher bar and its own button.
class IntentFilterBar extends StatelessWidget {
  const IntentFilterBar({
    super.key,
    required this.selected,
    required this.trustLevel,
    required this.onSelect,
  });

  /// Null = the "All" chip.
  final IntentType? selected;
  final int trustLevel;

  /// Called with null for "All", or the tapped intent — including a locked
  /// one, so the caller can explain the lock rather than the tap doing
  /// nothing.
  final void Function(IntentType? intent) onSelect;

  @override
  Widget build(BuildContext context) {
    // "All" first, then every intent in declaration order.
    final options = <IntentType?>[null, ...IntentType.values];

    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: options.length,
        separatorBuilder: (context, index) => const SizedBox(width: 7),
        itemBuilder: (context, index) {
          final intent = options[index];
          final isSelected = intent == selected;
          // "All" is never locked: it is a filter over whatever the viewer
          // can already see, and the server redacts per-meetup regardless.
          final locked = intent != null && !intent.canJoin(trustLevel);

          return Padding(
            // The row is 40 high and the chip is 32: this is what turns
            // the rest of it into tap area rather than dead space.
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: AppChip(
              key: ValueKey(intent?.name ?? 'all'),
              label: intent?.label ?? 'All',
              icon: intent == null ? AppIcons.grid : intent.iconPath,
              selected: isSelected,
              locked: locked,
              onTap: () => onSelect(intent),
            ),
          );
        },
      ),
    );
  }
}
