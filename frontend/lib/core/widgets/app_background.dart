import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The app's dark photo background.
///
/// # IT PAINTS ONCE, EVEN WHEN NESTED
///
/// A nested `AppBackground` returns its child untouched, because an ancestor
/// has already painted the same thing.
///
/// This is not micro-optimisation. Each instance is a full-screen
/// `Image.asset` wrapped in `Opacity` and `ColorFiltered` — an `Opacity`
/// over a full-screen subtree forces a `saveLayer`, and so does the colour
/// filter. Nesting two of them meant every frame of a page transition
/// composited two off-screen full-screen layers and held two decoded copies
/// of the same image, on the one tab that did it.
///
/// It also mattered for what the user actually sees. The `Container` below
/// paints a flat `AppPalette.onyx` fill FIRST, and `Image.asset` renders
/// nothing until its stream resolves — so an un-resolved background is a
/// plain grey panel. Two independent image streams are two chances to show
/// that.
///
/// `EventsPage` was the only one of the four `AppShell` tabs doing this. It
/// wraps itself because `meetup_detail_page.dart` also PUSHES it as a route,
/// and a pushed route is built under the `Navigator` — which sits ABOVE
/// `AppShell`, so it genuinely has no background ancestor and must paint its
/// own. Both entry paths stay correct: the marker below is only found when
/// the page really is inside another `AppBackground`.
class AppBackground extends StatelessWidget {
  const AppBackground({
    super.key,
    required this.child,
    this.imageOpacity = 0.28,
  });

  final Widget child;

  /// How strongly the photo reads, as authored for the DARK theme.
  ///
  /// Light mode scales this down — see [_effectiveImageOpacity]. Callers
  /// pass one number and get a result that works in both themes, rather than
  /// each of the eight call sites having to know about the difference.
  final double imageOpacity;

  /// The photo is a dark, desaturated image, so the same value does not read
  /// the same on both themes — over near-white it turns to grey cast rather
  /// than depth.
  ///
  /// TUNED TWICE. The first pass took light mode down to a third of the
  /// authored value AND pushed the veil below to 0.82, because at the time
  /// several cards were translucent and the photo showed through them as
  /// murk. Together those two changes made the image invisible.
  ///
  /// Those cards are opaque now (FlatCard composites its tint instead of
  /// replacing the surface), so the photo only ever meets the page
  /// background. It can afford to be seen: 60% of the authored value, with
  /// the veil pulled back to roughly dark mode's, gives light mode the same
  /// texture the dark theme has without the cast that started this.
  double get _effectiveImageOpacity =>
      AppPalette.isLight ? imageOpacity * 0.6 : imageOpacity;

  /// Marks the painted layer so a test can count how many actually rendered
  /// — the widget count alone cannot tell a painting instance from a
  /// pass-through one.
  @visibleForTesting
  static const Key layerKey = Key('appBackgroundLayer');

  @override
  Widget build(BuildContext context) {
    // getInheritedWidgetOfExactType, not dependOnInheritedWidgetOfExactType:
    // this never changes for a given position in the tree, so registering a
    // dependency would only add rebuild bookkeeping for a notification that
    // can never fire (updateShouldNotify is false).
    final alreadyPainted =
        context.getInheritedWidgetOfExactType<_AppBackgroundScope>() != null;
    if (alreadyPainted) return child;

    return _AppBackgroundScope(child: _buildLayer());
  }

  Widget _buildLayer() {
    return RepaintBoundary(
      key: layerKey,
      child: Container(
        color: AppPalette.onyx,
        child: Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: ColorFiltered(
                  colorFilter: const ColorFilter.mode(
                    Color(0xFF808080),
                    BlendMode.saturation,
                  ),
                  child: Opacity(
                    opacity: _effectiveImageOpacity,
                    child: Image.asset(
                      'assets/images/suit.png',
                      fit: BoxFit.cover,
                      cacheWidth: 1080, // Limit cache size
                      errorBuilder: (context, error, stackTrace) =>
                          const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.0, 0.5, 1.0],
                    // Light mode still veils a little harder — content sits
                    // directly on this and dark-on-light needs more
                    // separation than light-on-dark — but only a little.
                    // At 0.82 the photo was gone entirely.
                    colors: AppPalette.isLight
                        ? [
                            AppPalette.onyx.withValues(alpha: 0.55),
                            AppPalette.onyx.withValues(alpha: 0.80),
                            AppPalette.onyx,
                          ]
                        : [
                            AppPalette.onyx.withValues(alpha: 0.50),
                            AppPalette.onyx.withValues(alpha: 0.82),
                            AppPalette.onyx,
                          ],
                  ),
                ),
              ),
            ),
            Positioned.fill(child: child),
          ],
        ),
      ),
    );
  }
}

/// Present in the tree wherever an [AppBackground] has already painted.
///
/// Deliberately carries no data — its existence IS the information, which is
/// why [updateShouldNotify] is always false: nothing can change about it, so
/// nothing ever needs rebuilding on its account.
class _AppBackgroundScope extends InheritedWidget {
  const _AppBackgroundScope({required super.child});

  @override
  bool updateShouldNotify(_AppBackgroundScope oldWidget) => false;
}
