import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';

/// "There is more below" — a chevron that appears over the bottom of a
/// list and goes away once you reach the end.
///
/// # WHY A LIST NEEDS TO SAY THIS
///
/// A list between a fixed header and pinned buttons has no edge of its own
/// to run off: the last row you can see sits neatly above a divider, which
/// looks exactly like the end of the list whether it is or not. With twelve
/// people to rate and seven on screen, that is five people someone can
/// simply fail to notice, and the CONFIRM above them stays disabled with no
/// visible reason why.
///
/// So the list says so, and the chevron is also a control: tapping it pages
/// down, which is the shortcut anyone who sees it will try.
///
/// It hides itself when there is nothing below — including when the content
/// is shorter than the viewport, when it never appears at all.
///
/// # THE FADE UNDER IT
///
/// A chevron floating over a list lands on whatever row happens to be
/// there, which on a half-scrolled list means a circle sitting on somebody's
/// name. So it rides on a short gradient to the page ground
/// ([AppPalette.onyx], the one flat colour every page is painted on), and
/// rows dissolve into it rather than colliding with it. The fade is the
/// honest picture anyway: content continuing past the edge is exactly what
/// it depicts.
class ScrollMoreHint extends StatefulWidget {
  const ScrollMoreHint({super.key, required this.controller, this.bottom = 0});

  /// The controller of the scrollable this sits over. Must be the same one
  /// attached to that list, or the hint has no position to read.
  final ScrollController controller;

  /// Extra offset from the bottom of the stack it is placed in.
  final double bottom;

  /// Height of the fade strip. The list this sits over should carry at
  /// least this much bottom padding, so the last row clears it instead of
  /// ending underneath the chevron.
  static const stripHeight = 76.0;

  /// How close to the end counts as "the end". A couple of pixels of
  /// overscroll slop should not keep the chevron on screen.
  static const _endSlop = 24.0;

  @override
  State<ScrollMoreHint> createState() => _ScrollMoreHintState();
}

class _ScrollMoreHintState extends State<ScrollMoreHint> {
  bool _hasMore = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_update);
    // The controller has no clients until the list has laid out, so the
    // first honest answer is only available after this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void didUpdateWidget(ScrollMoreHint old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_update);
      widget.controller.addListener(_update);
      WidgetsBinding.instance.addPostFrameCallback((_) => _update());
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (!mounted) return;
    final controller = widget.controller;
    final hasMore =
        controller.hasClients &&
        controller.position.hasContentDimensions &&
        controller.position.maxScrollExtent - controller.position.pixels >
            ScrollMoreHint._endSlop;
    if (hasMore != _hasMore) setState(() => _hasMore = hasMore);
  }

  /// Pages down by most of a screen, leaving a little overlap so the row
  /// you were reading stays in sight.
  void _pageDown() {
    final position = widget.controller.position;
    widget.controller.animateTo(
      (position.pixels + position.viewportDimension * 0.8).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ground = AppPalette.onyx;
    return Positioned(
      left: 0,
      right: 0,
      bottom: widget.bottom,
      child: IgnorePointer(
        // Nothing here takes a tap while hidden; the chevron is the only
        // part that ever does.
        ignoring: !_hasMore,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          opacity: _hasMore ? 1 : 0,
          child: SizedBox(
            height: ScrollMoreHint.stripHeight,
            child: Stack(
              children: [
                // Paint only: rows keep scrolling and stay tappable under
                // it, so the fade costs the list nothing.
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            ground.withValues(alpha: 0),
                            ground.withValues(alpha: 0.85),
                            ground,
                          ],
                          stops: const [0.0, 0.55, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Semantics(
                      button: true,
                      label: 'More below',
                      child: Material(
                        color: AppPalette.card,
                        shape: const CircleBorder(),
                        elevation: 3,
                        shadowColor: ground.withValues(alpha: 0.35),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _pageDown,
                          child: SizedBox(
                            width: 36,
                            height: 36,
                            child: AppIcon(
                              AppIcons.chevronDown,
                              size: 22,
                              color: AppPalette.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
