import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The app's persistent bottom navigation bar (ADR-032 round 2 — renamed
/// from `GlassBottomBar`, which hadn't drawn glass since round 1).
///
/// Flush and edge-to-edge, not a floating pill: it used to be
/// `SafeArea > Padding(14, 0, 14, 14) > FlatCard(radius: 26)`, i.e. an
/// inset, heavily-rounded capsule with margin on all four sides. The
/// reference image (`frontend/flat-redesign-reference.png`, callout #3)
/// specifies a bar pinned flush to the bottom edge with a single top
/// hairline border and no rounding at all, so the side/bottom margins and
/// the `FlatCard` wrapper (which would draw a border on all four sides and
/// round the corners) are both gone.
///
/// The background is painted OUTSIDE the `SafeArea` so the bar's color
/// extends behind the home indicator / gesture area rather than leaving a
/// strip of page content showing beneath it, while the icons themselves
/// stay inset above it. `top: false` because only the bottom inset is
/// relevant here.
class AppBottomBar extends StatelessWidget {
  const AppBottomBar({super.key, required this.index, required this.onTap});

  final int index;
  final ValueChanged<int> onTap;

  static const List<_NavItem> _items = [
    _NavItem(Icons.home_outlined, Icons.home, 'HOME'),
    _NavItem(Icons.people_outline, Icons.people, 'MATCHES'),
    _NavItem(Icons.shield_outlined, Icons.shield, 'SAFETY'),
    _NavItem(Icons.chat_bubble_outline, Icons.chat_bubble, 'CHATS'),
    _NavItem(Icons.person_outline, Icons.person, 'PROFILE'),
  ];

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppPalette.card,
        border: Border(top: BorderSide(color: AppPalette.glassBorder)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          child: Row(
            children: List.generate(_items.length, (i) {
              final item = _items[i];
              final bool selected = i == index;
              return Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onTap(i),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        selected ? item.activeIcon : item.icon,
                        size: 21,
                        color: selected
                            ? AppPalette.candyBlue
                            : AppPalette.textSecondary,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.label,
                        style: TextStyle(
                          fontSize: 8,
                          letterSpacing: 1.4,
                          fontWeight: FontWeight.w600,
                          color: selected
                              ? AppPalette.candyBlue
                              : AppPalette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  const _NavItem(this.icon, this.activeIcon, this.label);

  final IconData icon;
  final IconData activeIcon;
  final String label;
}
