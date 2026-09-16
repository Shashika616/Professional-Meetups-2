import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';

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
/// The chip shape is carried over from the deleted browse page's own filter
/// row, which was already this shape.
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
        separatorBuilder: (context, index) => const SizedBox(width: 14),
        itemBuilder: (context, index) {
          final intent = options[index];
          final isSelected = intent == selected;
          // "All" is never locked: it is a filter over whatever the viewer
          // can already see, and the server redacts per-meetup regardless.
          final locked = intent != null && !intent.canJoin(trustLevel);

          return _FilterChip(
            key: ValueKey(intent?.name ?? 'all'),
            label: intent?.label ?? 'ALL',
            icon: intent == null
                ? Icons.apps_rounded
                : (locked ? Icons.lock_outline : intent.icon),
            selected: isSelected,
            locked: locked,
            onTap: () => onSelect(intent),
          );
        },
      ),
    );
  }
}

/// One tab: the icon in front of the word, and a short bar under the
/// chosen one in the accent colour. Text tabs rather than pills, the way
/// a shop's category row reads: the words are navigation, not buttons, so
/// they carry no box of their own. The bar is what says which is on. A
/// locked intent is dimmed with its lock in place of its icon.
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.locked,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppPalette.brandGreen;
    final foreground = locked
        ? AppPalette.textSecondary.withValues(alpha: 0.7)
        : (selected ? accent : AppPalette.textSecondary);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: foreground),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    letterSpacing: 0.6,
                    color: foreground,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              height: 3,
              width: selected ? 28 : 0,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
