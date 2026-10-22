import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';

/// A selectable pill in a horizontal filter row.
///
/// Three states, and each one has to be distinguishable from the other two
/// at a glance and without colour alone:
///
///  * **unselected** — [AppPalette.raised] fill, secondary label.
///  * **selected** — accent-tinted fill, accent label, heavier weight. The
///    weight change is what carries the state for a user who cannot
///    separate the two fills.
///  * **locked** — tertiary label and a padlock REPLACING the icon. Locked
///    chips stay visible and stay tappable; the caller explains the gate.
///    Hiding them would leave someone unable to discover that the thing
///    exists or what unlocks it.
class AppChip extends StatelessWidget {
  const AppChip({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.selected = false,
    this.locked = false,
  });

  final String label;
  final VoidCallback onTap;

  /// One of the `AppIcons.*` stroke paths.
  final String? icon;
  final bool selected;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final Color fg = locked
        ? AppPalette.textTertiary
        : (selected ? AppPalette.candyBlue : AppPalette.textSecondary);
    final Color fill = selected
        ? Color.alphaBlend(AppPalette.accentTint, AppPalette.card)
        : AppPalette.raised;
    final String? glyph = locked ? AppIcons.lock : icon;

    return Semantics(
      button: true,
      selected: selected,
      enabled: true,
      label: locked ? '$label, locked' : label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          // 32 visually; the row that hosts these gives them the rest of
          // the 44px touch target as vertical padding.
          constraints: const BoxConstraints(minHeight: 32),
          padding: const EdgeInsets.symmetric(horizontal: 13),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(99),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (glyph != null) ...[
                AppIcon(glyph, size: 14, color: fg),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 12,
                  letterSpacing: 0.1,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
