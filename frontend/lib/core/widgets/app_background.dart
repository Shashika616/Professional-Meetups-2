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

  /// The photo is a dark, desaturated image. On the dark theme it reads as
  /// depth. On the light theme the same value sits behind near-white
  /// surfaces and reads as grey murk — the whole screen looks dirty, and
  /// anything translucent above it looks worse.
  ///
  /// A third of the authored value keeps the texture without the cast. Not
  /// zero: the photo is the app's one piece of visual identity, and dropping
  /// it entirely in light mode would make the two themes look like two
  /// different products.
  double get _effectiveImageOpacity =>
      AppPalette.isLight ? imageOpacity * 0.33 : imageOpacity;

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
                    // Light mode starts the veil far more opaque. The dark
                    // theme wants the photo visible at the top of the
                    // screen; the light theme wants it to be a texture you
                    // stop noticing, because content sits directly on it.
                    colors: AppPalette.isLight
                        ? [
                            AppPalette.onyx.withValues(alpha: 0.82),
                            AppPalette.onyx.withValues(alpha: 0.94),
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
