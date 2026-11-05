import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/brand_loader.dart';

/// The launch moment. The two figures of the mark are a tie, so they draw
/// themselves from opposite sides, meet and fill while the name sets. When the
/// app opens the same animation runs backwards: [progress] goes from 0 to 1 to
/// build the mark, and from 1 back to 0 to take it apart.
///
/// Painted rather than built from widgets, because the name sets letter by
/// letter.
class SplashArt extends StatelessWidget {
  const SplashArt({super.key, required this.progress});

  static const size = Size(280, 268);

  final Animation<double> progress;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'TieHere',
      image: true,
      child: CustomPaint(
        size: size,
        painter: _SplashArtPainter(
          progress: progress,
          ink: AppPalette.textPrimary,
        ),
      ),
    );
  }
}

class _SplashArtPainter extends CustomPainter {
  _SplashArtPainter({required this.progress, required this.ink})
    : super(repaint: progress);

  final Animation<double> progress;
  final Color ink;

  static const _markSize = 212.0;
  static const _nameTop = 208.0;
  static const _fontSize = 36.0;
  static const _word = 'TieHere';

  static double _span(double t, double from, double to) =>
      ((t - from) / (to - from)).clamp(0.0, 1.0);

  /// Fast, then settling: nothing in the build overshoots.
  static double _settle(double t) => 1 - math.pow(1 - t, 4).toDouble();

  @override
  void paint(Canvas canvas, Size size) {
    final built = progress.value;
    if (built <= 0) return;
    const scale = _markSize / 1024;
    canvas.save();
    canvas.translate((size.width - _markSize) / 2, 0);
    canvas.scale(scale);
    _paintFigures(canvas, TieHereMarkPaths.instance, built);
    canvas.restore();
    _paintName(canvas, size, built);
  }

  void _paintFigures(Canvas canvas, TieHereMarkPaths geometry, double t) {
    final meet = _settle(_span(t, 0, 0.62));
    final fill = _span(t, 0.38, 0.66);
    final trace = Curves.easeInOutCubic.transform(_span(t, 0, 0.5));
    final apart = (1 - meet) * 150;
    for (final (path, outline, colour, shift) in [
      (geometry.blue, geometry.blueOutline, AppPalette.brandBlue, -apart),
      (geometry.green, geometry.greenOutline, AppPalette.brandGreen, apart),
    ]) {
      canvas.save();
      canvas.translate(shift, 0);
      if (fill < 1) {
        canvas.drawPath(
          TieHereMarkPaths.trace(outline, trace),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 9
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..color = colour,
        );
      }
      if (fill > 0) {
        canvas.drawPath(path, Paint()..color = colour.withValues(alpha: fill));
      }
      canvas.restore();
    }
  }

  void _paintName(Canvas canvas, Size size, double built) {
    final whole = TextPainter(
      text: _wordSpan(_word),
      textDirection: TextDirection.ltr,
    )..layout();
    final left = (size.width - whole.width) / 2;
    for (var i = 0; i < _word.length; i++) {
      final start = 0.5 + i * 0.045;
      final appear = _settle(_span(built, start, start + 0.26));
      if (appear <= 0) continue;
      final box = whole
          .getBoxesForSelection(
            TextSelection(baseOffset: i, extentOffset: i + 1),
          )
          .first;
      final letter = TextPainter(
        text: TextSpan(
          text: _word[i],
          style: _style(
            i,
          ).copyWith(color: _colour(i).withValues(alpha: appear)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      letter.paint(
        canvas,
        Offset(left + box.left, _nameTop + (1 - appear) * 14),
      );
      letter.dispose();
    }
    whole.dispose();
  }

  TextSpan _wordSpan(String word) => TextSpan(
    children: [
      for (var i = 0; i < word.length; i++)
        TextSpan(text: word[i], style: _style(i)),
    ],
  );

  /// "Tie" in the ink colour and "Here" in brand green, as the wordmark is set.
  Color _colour(int i) => i < 3 ? ink : AppPalette.brandGreen;

  TextStyle _style(int i) => TextStyle(
    fontSize: _fontSize,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.6,
    height: 1.05,
    color: _colour(i),
  );

  @override
  bool shouldRepaint(_SplashArtPainter old) => old.ink != ink;
}
