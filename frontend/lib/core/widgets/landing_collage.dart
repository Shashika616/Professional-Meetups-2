import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The landing page's moving backdrop: columns of scene cards drifting
/// downward, forever, swapping for new images as they wrap.
///
/// # WHY A TICKER AND NOT A SCROLLVIEW
///
/// The obvious build is three ListViews auto scrolled by controllers. It is
/// the wrong tool: a ScrollController animating forever fights the physics
/// simulation, accumulates floating point drift over minutes, and has to be
/// stopped and restarted to loop, which shows as a stutter at the seam.
///
/// Here the offset is DERIVED from elapsed time rather than accumulated, so it
/// cannot drift, and the wrap is a modulo with no seam to see.
///
/// # HOW IT STAYS CHEAP
///
/// This runs behind a sign in screen on whatever phone the user owns, so the
/// per frame cost is the design constraint, not an afterthought. Four things
/// carry it:
///
///  1. NOTHING REBUILDS PER FRAME. The first version called setState in the
///     ticker, which rebuilt three columns of eight Image widgets sixty times
///     a second. Now the ticker only writes to a ValueNotifier, and each
///     column is an AnimatedBuilder whose `child` holds the tiles. Flutter
///     passes that child through untouched, so a frame builds three Transforms
///     and nothing else.
///  2. NOTHING REPAINTS PER FRAME. The tiles sit inside a RepaintBoundary, so
///     they rasterise once and the Transform above them only moves the
///     resulting layer. That is a compositor operation on the GPU, not a
///     canvas repaint.
///  3. IMAGES DECODE ONCE, SMALL. Every tile passes cacheWidth, so a 520px
///     source is decoded at the ~120px it is actually drawn at. Without it the
///     backdrop alone would hold most of a phone's image cache.
///  4. IT STOPS WHEN IT IS NOT SEEN. createTicker is muted by TickerMode,
///     which Flutter switches off for routes covered by another route, so
///     pushing the sign in page silences this rather than leaving it running
///     behind the covering page.
///
/// It also honours the platform "reduce motion" setting, which is both an
/// accessibility requirement and a free escape hatch on a device that cannot
/// keep up: the grid still renders, it simply does not move.
///
/// # WHY THE IMAGES ARE SWAPPED RATHER THAN CYCLED
///
/// A fixed rotation of fifteen tiles is recognisable within about two loops,
/// and once the repeat is noticed the backdrop stops feeling alive. Each time
/// a column wraps, the tile that just left is refilled with a random image.
class LandingCollage extends StatefulWidget {
  const LandingCollage({super.key});

  /// Every tile in assets/images/landing. Listed explicitly rather than
  /// discovered, because the asset bundle has no directory listing at runtime
  /// and a missing file would otherwise fail silently at paint time.
  static const List<String> assets = <String>[
    'assets/images/landing/l01.jpg',
    'assets/images/landing/l02.jpg',
    'assets/images/landing/l03.jpg',
    'assets/images/landing/l04.jpg',
    'assets/images/landing/l05.jpg',
    'assets/images/landing/l06.jpg',
    'assets/images/landing/l07.jpg',
    'assets/images/landing/l08.jpg',
    'assets/images/landing/l09.jpg',
    'assets/images/landing/l10.jpg',
    'assets/images/landing/l11.jpg',
    'assets/images/landing/l12.jpg',
    'assets/images/landing/l13.jpg',
    'assets/images/landing/l14.jpg',
    'assets/images/landing/l15.jpg',
    'assets/images/landing/l16.jpg',
    'assets/images/landing/l17.jpg',
    'assets/images/landing/l18.jpg',
    'assets/images/landing/l19.jpg',
    'assets/images/landing/l20.jpg',
    'assets/images/landing/l21.jpg',
    'assets/images/landing/l22.jpg',
    'assets/images/landing/l23.jpg',
    'assets/images/landing/l24.jpg',
    'assets/images/landing/l25.jpg',
    'assets/images/landing/l26.jpg',
    'assets/images/landing/l27.jpg',
    'assets/images/landing/l28.jpg',
    'assets/images/landing/l29.jpg',
  ];

  @override
  State<LandingCollage> createState() => _LandingCollageState();
}

class _LandingCollageState extends State<LandingCollage>
    with SingleTickerProviderStateMixin {
  static const int _columns = 3;
  static const double _gap = 10;
  static const double _tileAspect = 520 / 390;

  /// Logical pixels per second. Slow on purpose: this sits behind a sign in
  /// screen, and anything faster reads as a distraction rather than as
  /// atmosphere.
  static const double _baseSpeed = 13;

  late final Ticker _ticker;
  final math.Random _rng = math.Random();

  /// A shuffled deck of image indices, drawn from and refilled when empty.
  ///
  /// Plain `nextInt(assets.length)` was not good enough. With roughly two
  /// dozen tiles on screen at once, independent uniform picks put the same
  /// image near itself often enough to notice, and that is exactly what makes
  /// a collage read as a repeating texture rather than a wall of different
  /// moments. A deck guarantees every image is used once before any is reused.
  final List<int> _deck = <int>[];

  /// Written every frame, read only by the AnimatedBuilders. Deliberately not
  /// State: a setState here would defeat the whole arrangement.
  final ValueNotifier<double> _seconds = ValueNotifier<double>(0);

  late List<List<int>> _slots;
  late List<int> _lastWrap;
  int _rows = 0;
  double _step = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    final seconds = elapsed.inMicroseconds / 1e6;
    _seconds.value = seconds;

    // The only thing that can require a rebuild is a column wrapping, which
    // happens a handful of times a minute rather than sixty times a second.
    if (_step <= 0) return;
    var wrapped = false;
    for (var c = 0; c < _columns; c++) {
      final wraps = (seconds * _speedOf(c)) ~/ _step;
      if (wraps != _lastWrap[c]) {
        _lastWrap[c] = wraps;
        final slots = _slots[c];
        slots.insert(0, _draw());
        slots.removeLast();
        wrapped = true;
      }
    }
    if (wrapped && mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    _seconds.dispose();
    super.dispose();
  }

  void _refillDeck() {
    _deck
      ..clear()
      ..addAll(List<int>.generate(LandingCollage.assets.length, (i) => i))
      ..shuffle(_rng);
  }

  /// Draws the next image, preferring one not already on screen.
  ///
  /// The deck fixes long run repetition; this fixes the local case. A card
  /// that would duplicate something currently visible goes to the BOTTOM of
  /// the deck rather than being discarded, so it returns later instead of
  /// dropping out of the rotation.
  int _draw() {
    final visible = <int>{for (final column in _slots) ...column};
    for (var tries = 0; tries < 8; tries++) {
      if (_deck.isEmpty) _refillDeck();
      final candidate = _deck.removeLast();
      if (!visible.contains(candidate)) return candidate;
      _deck.insert(0, candidate);
    }
    if (_deck.isEmpty) _refillDeck();
    return _deck.removeLast();
  }

  void _ensureSlots(int rows) {
    if (_rows == rows) return;
    _rows = rows;
    // Built row by row with _draw so the FIRST screen is already well spread.
    // Filling it with independent picks and only spreading later would mean
    // the one screen most people ever see is the worst one.
    _slots = List<List<int>>.generate(_columns, (_) => <int>[]);
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < _columns; c++) {
        _slots[c].add(_draw());
      }
    }
    _lastWrap = List<int>.filled(_columns, 0);
  }

  /// Columns run at slightly different speeds so the grid never locks into
  /// horizontal bands, which is what makes a multi column marquee read as one
  /// sliding sheet instead of three separate columns.
  double _speedOf(int column) => _baseSpeed * (1.0 + column * 0.22);

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion && _ticker.isActive) {
      _ticker.stop();
    } else if (!reduceMotion && !_ticker.isActive) {
      _ticker.start();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final colW = (w - _gap * (_columns - 1)) / _columns;
        final tileH = colW / _tileAspect;
        _step = tileH + _gap;

        // One row above and one below the viewport, so a tile is never seen
        // entering or leaving mid frame.
        _ensureSlots((h / _step).ceil() + 2);

        return ClipRect(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var c = 0; c < _columns; c++) ...[
                if (c > 0) const SizedBox(width: _gap),
                SizedBox(
                  width: colW,
                  height: h,
                  child: _column(c, colW, tileH),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _column(int c, double colW, double tileH) {
    final speed = _speedOf(c);
    final step = _step;

    return AnimatedBuilder(
      animation: _seconds,
      // Built here, ONCE per wrap. AnimatedBuilder hands it back to the
      // builder untouched, so the per frame work below never walks the tiles.
      child: RepaintBoundary(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (var r = 0; r < _slots[c].length; r++)
              Positioned(
                left: 0,
                // Stack with explicit offsets, not a Column: this holds MORE
                // tiles than fit on screen and a Column asserts on exactly
                // that ("A RenderFlex overflowed by 640 pixels"). ClipRect
                // hides it visually, but the assertion still fails any test
                // that renders the page.
                top: r * step,
                width: colW,
                height: tileH,
                child: _Tile(asset: LandingCollage.assets[_slots[c][r]]),
              ),
          ],
        ),
      ),
      builder: (context, child) => Transform.translate(
        offset: Offset(0, (_seconds.value * speed) % step - step),
        child: child,
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.asset});

  final String asset;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.asset(
        asset,
        fit: BoxFit.cover,
        // Decoded at the size actually drawn rather than the asset's 520px.
        // The tile is roughly a third of the screen wide, so this is the
        // difference between a few MB of decoded bitmaps and tens of MB.
        cacheWidth:
            (MediaQuery.sizeOf(context).width /
                    3 *
                    MediaQuery.devicePixelRatioOf(context))
                .round(),
        gaplessPlayback: true,
        excludeFromSemantics: true,
        // Until the first frame decodes, paint the card colour rather than
        // nothing: on a slow decoder (the emulator, an old phone) the
        // columns otherwise fill in one at a time over several seconds and
        // the empty ones read as holes in the page.
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
            frame == null && !wasSynchronouslyLoaded
            ? ColoredBox(color: AppPalette.card)
            : child,
        errorBuilder: (_, _, _) => ColoredBox(color: AppPalette.card),
      ),
    );
  }
}
