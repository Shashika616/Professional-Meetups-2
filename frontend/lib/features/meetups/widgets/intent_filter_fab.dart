import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/reduced_motion.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/pressable.dart';

/// The selected fill of the app's chips, laid on the surface so it stays solid
/// over the cards it floats above.
Color get _selectedSurface =>
    Color.alphaBlend(AppPalette.accentTint, AppPalette.raised);

const double _itemSize = 48;
const double _itemGap = 10;

/// The floating intent filter: a button in the app's own surface, showing the chosen intent's
/// icon, which turns the accent blue while a filter is on. One tap opens a speed dial, each intent its own small button rising
/// out of it, with All at the top.
///
/// Intents the viewer cannot join stay in the dial with a lock, and tapping
/// one still calls [onSelect] so the caller can explain why. A null
/// [trustLevel] means locks do not apply, as on the viewer's own meetups.
class IntentFilterFab extends StatelessWidget {
  const IntentFilterFab({
    super.key,
    required this.selected,
    required this.onSelect,
    this.trustLevel,
  });

  /// Null means All.
  final IntentType? selected;
  final int? trustLevel;
  final ValueChanged<IntentType?> onSelect;

  static const double size = 56;

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject()! as RenderBox;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final picked = await showGeneralDialog<({IntentType? intent})>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close intent filter',
      barrierColor: Colors.black.withValues(alpha: 0.62),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, _, _) => _SpeedDial(
        anchor: anchor,
        selected: selected,
        trustLevel: trustLevel,
      ),
    );
    if (picked != null) onSelect(picked.intent);
  }

  @override
  Widget build(BuildContext context) {
    final motion = reducedMotion(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    return Semantics(
      container: true,
      button: true,
      label: 'Filter by intent. Showing ${selected?.label ?? 'All'}',
      excludeSemantics: true,
      child: Tooltip(
        message: 'Filter by intent',
        child: Pressable(
          key: const Key('intent-fab'),
          onTap: () => _open(context),
          child: _Disc(
            child: AnimatedSwitcher(
              duration: motion,
              transitionBuilder: (child, animation) => ScaleTransition(
                scale: Tween<double>(begin: 0.6, end: 1).animate(animation),
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: AppIcon(
                selected?.iconPath ?? AppIcons.grid,
                key: ValueKey(selected),
                size: 24,
                color: selected == null
                    ? AppPalette.textPrimary
                    : AppPalette.candyBlue,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Disc extends StatelessWidget {
  const _Disc({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: IntentFilterFab.size,
      height: IntentFilterFab.size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppPalette.raised,
        border: Border.all(color: AppPalette.hairline),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: AppPalette.isLight ? 0.12 : 0.35,
            ),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _SpeedDial extends StatelessWidget {
  const _SpeedDial({
    required this.anchor,
    required this.selected,
    required this.trustLevel,
  });

  final Rect anchor;
  final IntentType? selected;
  final int? trustLevel;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final route = ModalRoute.of(context)!.animation!;
    final calm = reducedMotion(context);
    final options = <IntentType?>[null, ...IntentType.values];
    // Lines the small buttons up on the centre of the big one.
    final inset = (IntentFilterFab.size - _itemSize) / 2;
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned(
            right: media.size.width - anchor.right + inset,
            bottom: media.size.height - anchor.top + 14,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                // Below the status bar, scrolling if the text is large.
                maxHeight: anchor.top - 14 - media.padding.top - 8,
                maxWidth: media.size.width - 32,
              ),
              child: SingleChildScrollView(
                reverse: true,
                clipBehavior: Clip.none,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final (index, intent) in options.indexed)
                      _Arrival(
                        // The one nearest the button comes first.
                        order: options.length - 1 - index,
                        route: route,
                        calm: calm,
                        child: _DialItem(
                          intent: intent,
                          selected: intent == selected,
                          locked:
                              intent != null &&
                              trustLevel != null &&
                              !intent.canJoin(trustLevel!),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Positioned.fromRect(
            rect: anchor,
            child: Semantics(
              button: true,
              label: 'Close intent filter',
              excludeSemantics: true,
              child: Pressable(
                key: const Key('intent-fab-close'),
                onTap: () => Navigator.of(context).pop(),
                child: _Disc(
                  child: RotationTransition(
                    turns: calm
                        ? const AlwaysStoppedAnimation(0)
                        : Tween<double>(begin: -0.25, end: 0).animate(
                            CurvedAnimation(
                              parent: route,
                              curve: Curves.easeOutCubic,
                            ),
                          ),
                    child: AppIcon(
                      AppIcons.close,
                      size: 24,
                      color: AppPalette.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Rises out of the button, one after another.
class _Arrival extends StatelessWidget {
  const _Arrival({
    required this.order,
    required this.route,
    required this.calm,
    required this.child,
  });

  final int order;
  final Animation<double> route;
  final bool calm;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (calm) return child;
    final start = order * 0.06;
    final curved = CurvedAnimation(
      parent: route,
      curve: Interval(start, start + 0.55, curve: Curves.easeOutBack),
      reverseCurve: Curves.easeIn,
    );
    return FadeTransition(
      opacity: route.drive(CurveTween(curve: Interval(start, start + 0.3))),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.5),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

class _DialItem extends StatelessWidget {
  const _DialItem({
    required this.intent,
    required this.selected,
    required this.locked,
  });

  final IntentType? intent;
  final bool selected;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final label = intent?.label ?? 'All';
    return Padding(
      padding: const EdgeInsets.only(bottom: _itemGap),
      child: Semantics(
        container: true,
        button: true,
        selected: selected,
        label: locked ? '$label, locked' : label,
        excludeSemantics: true,
        child: Pressable(
          key: ValueKey('intent-${intent?.name ?? 'all'}'),
          onTap: () => Navigator.of(context).pop((intent: intent)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: AppPalette.raised,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected
                          ? AppPalette.candyBlue
                          : locked
                          ? AppPalette.textSecondary
                          : AppPalette.textPrimary,
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _button(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _button() {
    return SizedBox.square(
      dimension: _itemSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: _itemSize,
            height: _itemSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? _selectedSurface : AppPalette.raised,
              border: Border.all(color: AppPalette.hairline),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: AppIcon(
              intent?.iconPath ?? AppIcons.grid,
              size: 21,
              color: selected
                  ? AppPalette.candyBlue
                  : locked
                  ? AppPalette.textSecondary
                  : AppPalette.textPrimary,
            ),
          ),
          if (locked)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppPalette.card,
                  border: Border.all(color: AppPalette.hairline),
                ),
                child: AppIcon(
                  AppIcons.lock,
                  size: 11,
                  color: AppPalette.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
