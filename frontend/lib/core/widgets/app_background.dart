import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The app's page ground: one flat colour, painted once.
///
/// # IT PAINTS ONCE, EVEN WHEN NESTED
///
/// A nested `AppBackground` returns its child untouched, because an ancestor
/// has already painted the same thing.
///
/// `EventsPage` is why the guard exists: it wraps itself because
/// `meetup_detail_page.dart` also PUSHES it as a route, and a pushed route is
/// built under the `Navigator` - which sits ABOVE `AppShell`, so it genuinely
/// has no background ancestor and must paint its own. Both entry paths stay
/// correct; the marker below is only found when the page really is inside
/// another `AppBackground`.
///
/// # THIS USED TO BE A PHOTOGRAPH
///
/// It was a full-screen `Image.asset` under an `Opacity` and a
/// `ColorFiltered`, with a three-stop gradient veil on top to keep text
/// readable over it, and a per-theme opacity curve because the same photo
/// read as depth on black and as grey cast on white. Retired with the
/// TieHere rebrand: the mark is a saturated blue/green figure pair, and a
/// desaturated stock photo behind it fought the brand rather than supporting
/// it.
///
/// What replaced it is [AppPalette.onyx] itself - the same near-black the
/// surface ramp is already built from, so the ground and the cards on it come
/// from one scale instead of two. A brand-navy ground was tried first and
/// looked wrong: the mark is a saturated blue/green, and a blue ground behind
/// it muddied both.
///
/// It is also cheaper by construction. An `Opacity` over a full-screen
/// subtree forces a `saveLayer`, and so does a colour filter; both are gone,
/// along with the decoded full-screen image every route held. What is left is
/// one `Container` with a colour.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

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
    // RepaintBoundary is kept even though a flat fill is cheap to repaint:
    // it stops a repaint anywhere in the page subtree from dirtying the
    // ground, which is what it was there for before the photo existed.
    // SizedBox.expand is load-bearing, not decoration.
    //
    // `Container(color: x, child: y)` sizes itself to y. On a page whose
    // content is shorter than the viewport - the email sign-in step, for one -
    // that meant the ground stopped where the content stopped and the rest of
    // the screen fell through to bare black, in both themes. The photo version
    // never showed this because its Stack held `Positioned.fill` children,
    // which forced expansion as a side effect.
    //
    // Expanding first and colouring inside makes filling the viewport the
    // widget's actual contract rather than something inherited from whatever
    // happened to be in the tree.
    return RepaintBoundary(
      key: layerKey,
      child: SizedBox.expand(
        child: ColoredBox(color: AppPalette.onyx, child: child),
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
