import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';

/// The app's persistent bottom navigation.
///
/// # IT FLOATS AGAIN (2026-10 redesign)
///
/// This has now been both things twice, so here is the actual reasoning
/// rather than another "the reference says so".
///
/// It was a floating capsule, then ADR-032 pinned it flush to the bottom
/// edge with a single top hairline. Flush was the right call *at the time*:
/// the app had a photographic page background, and an inset bar let a strip
/// of photo show in the margins around it, which looked like a rendering
/// bug. With a flat ground there is no photo to leak, and flush has its own
/// cost — a full-width bar with a line above it is a piece of furniture the
/// eye has to step over on every screen.
///
/// So: a rounded pill, inset [_inset] on three sides, with the page colour
/// around it.
///
/// # WHY IT STILL RESERVES ITS OWN HEIGHT
///
/// `AppShell` keeps `extendBody: false`, so the page lays out ABOVE this
/// widget rather than scrolling under it. A translucent bar with content
/// sliding beneath is the prettier version and it is deliberately not what
/// this does: it would require every scrollable in the app to grow bottom
/// padding by hand, and the first one anybody forgot would hide a button
/// under the pill. The pill is translucent anyway ([AppPalette.navSurface]
/// + a blur) so it still reads as a floating layer, it simply has page
/// colour behind it instead of content.
///
/// That page colour is [AppPalette.onyx] — NOT a guess. The bar sits at the
/// very bottom of the screen and [AppPalette.backgroundGradient]'s bottom
/// stop *is* `onyx`, so the fill meets the page with no seam.
class AppBottomBar extends StatelessWidget {
  const AppBottomBar({super.key, required this.index, required this.onTap});

  final int index;
  final ValueChanged<int> onTap;

  /// The gap between the pill and the screen edge on three sides.
  static const double _inset = 12;

  // Chats is deliberately removed for now (2026-09-08) — the whole feature
  // is a static, backend-less placeholder (frontend/lib/features/chats/
  // chats_page.dart), never wired to anything real. Left in place rather
  // than deleted, matching this codebase's usual "defer, don't delete"
  // treatment (see ADR-004's rideShare/dating precedent) — just disconnect
  // it from navigation until it's actually built.
  // ONE GLYPH PER TAB, not an outline/filled pair.
  //
  // Material's convention is to swap an outlined icon for a filled one on
  // selection. The screen set does not: every icon in the app is the same
  // 1.6px stroke, and the selected tab is marked by COLOUR and WEIGHT
  // instead. Swapping to a solid glyph here would make the one selected
  // item the only filled icon anywhere in the app.
  static const List<_NavItem> _items = [
    _NavItem(AppIcons.home, 'Home'),
    _NavItem(AppIcons.events, 'Events'),
    _NavItem(AppIcons.safety, 'Safety'),
    _NavItem(AppIcons.profile, 'Profile'),
  ];

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppPalette.onyx,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(_inset, 0, _inset, _inset),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(26),
            child: BackdropFilter(
              // Nothing scrolls under this bar (see the class doc), so the
              // blur has only the flat page colour to work on. It is kept
              // because a dialog, a sheet or an open keyboard CAN pass
              // behind it, and because the saturation bump is what keeps
              // the translucent fill from going grey.
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppPalette.navSurface,
                  borderRadius: BorderRadius.circular(26),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: AppPalette.isLight ? 0.08 : 0.3,
                      ),
                      blurRadius: 22,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 7, 4, 6),
                  child: Row(
                    children: List.generate(_items.length, (i) {
                      return Expanded(
                        child: _NavButton(
                          item: _items[i],
                          selected: i == index,
                          onTap: () => onTap(i),
                        ),
                      );
                    }),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Inactive is textTertiary, not textSecondary: three of the four items
    // are always inactive, and at textSecondary they read as four equally
    // live options with one of them tinted.
    final Color color = selected
        ? AppPalette.candyBlue
        : AppPalette.textTertiary;

    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: ConstrainedBox(
          // 44 is the platform minimum touch target on both OSes; the
          // visual content is shorter than that, so this is the thing
          // keeping the tap area honest.
          constraints: const BoxConstraints(minHeight: 44),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AppIcon(
                item.icon,
                size: 21,
                color: color,
                // The selected tab's line thickens slightly. It is the same
                // cue the bolder label gives, applied to the glyph, so
                // colour is not the only signal of which tab is active.
                strokeWidth: selected ? 2.0 : 1.6,
              ),
              const SizedBox(height: 3),
              Text(
                item.label,
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 0.1,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  const _NavItem(this.icon, this.label);

  /// One of the `AppIcons.*` path constants.
  final String icon;
  final String label;
}
