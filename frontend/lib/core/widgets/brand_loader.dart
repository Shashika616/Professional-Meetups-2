import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/tiehere_mark_paths.dart';

/// The mark as paths, in its 1024 unit box.
class TieHereMarkPaths {
  TieHereMarkPaths._();

  static final instance = TieHereMarkPaths._();

  final Path blue = _parse(tieHereBlueFigure);
  final Path green = _parse(tieHereGreenFigure);

  late final List<PathMetric> blueOutline = blue.computeMetrics().toList();
  late final List<PathMetric> greenOutline = green.computeMetrics().toList();

  /// [outline] drawn as far as [amount], 0 to 1.
  static Path trace(List<PathMetric> outline, double amount) {
    final path = Path();
    for (final metric in outline) {
      path.addPath(metric.extractPath(0, metric.length * amount), Offset.zero);
    }
    return path;
  }

  /// M, C and Z are the only commands in the traced figures.
  static Path _parse(String data) {
    final path = Path()..fillType = PathFillType.evenOdd;
    final values = <double>[];
    String? command;
    void flush() {
      if (command == 'M' && values.length >= 2) {
        path.moveTo(values[0], values[1]);
      } else if (command == 'C') {
        for (var i = 0; i + 5 < values.length; i += 6) {
          path.cubicTo(
            values[i],
            values[i + 1],
            values[i + 2],
            values[i + 3],
            values[i + 4],
            values[i + 5],
          );
        }
      }
      values.clear();
    }

    for (final match in RegExp(r'[MCZ]|-?\d+(?:\.\d+)?').allMatches(data)) {
      final token = match.group(0)!;
      if (token == 'M' || token == 'C' || token == 'Z') {
        flush();
        command = token;
        if (token == 'Z') path.close();
      } else {
        values.add(double.parse(token));
      }
    }
    flush();
    return path;
  }
}

/// The app's one loading indicator: the two figures of the mark draw
/// themselves, fill, and unwind, the same movement as the splash.
///
/// [color] draws both figures in one colour, for a surface the brand colours
/// would vanish on, such as the green primary button. With reduce motion on,
/// the finished mark stays still.
class BrandLoader extends StatefulWidget {
  const BrandLoader({super.key, this.size = 28, this.color});

  final double size;
  final Color? color;

  @override
  State<BrandLoader> createState() => _BrandLoaderState();
}

class _BrandLoaderState extends State<BrandLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _controller
        ..stop()
        ..value = 0.5;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading',
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _LoaderPainter(_controller, widget.color),
        ),
      ),
    );
  }
}

class _LoaderPainter extends CustomPainter {
  _LoaderPainter(this.time, this.color) : super(repaint: time);

  final Animation<double> time;
  final Color? color;

  /// The figures fill about this much of the 1024 box.
  static const _markSpan = 660.0;

  @override
  void paint(Canvas canvas, Size size) {
    final mark = TieHereMarkPaths.instance;
    // Out and back: 0 at the start of the loop, 1 at the middle.
    final wave = 1 - (2 * time.value - 1).abs();
    final built = Curves.easeInOutCubic.transform(wave);
    final trace = (built / 0.72).clamp(0.0, 1.0);
    final fill = ((built - 0.62) / 0.38).clamp(0.0, 1.0);
    final scale = size.width / _markSpan;
    // Thin enough to read as a line at 16, never finer than a hairline.
    final stroke = math.max(size.width * 0.07, 1.6) / scale;
    final apart = (1 - built) * 60;

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);
    canvas.translate(-512, -512);
    for (final (path, outline, brand, shift) in [
      (mark.blue, mark.blueOutline, AppPalette.brandBlue, -apart),
      (mark.green, mark.greenOutline, AppPalette.brandGreen, apart),
    ]) {
      final colour = color ?? brand;
      canvas.save();
      canvas.translate(shift, 0);
      if (fill < 1 && trace > 0) {
        canvas.drawPath(
          TieHereMarkPaths.trace(outline, trace),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
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
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LoaderPainter old) => old.color != color;
}

/// Pull to refresh with [BrandLoader] in place of the Material spinner.
class BrandRefreshIndicator extends StatefulWidget {
  const BrandRefreshIndicator({
    super.key,
    required this.onRefresh,
    required this.child,
  });

  final RefreshCallback onRefresh;
  final Widget child;

  @override
  State<BrandRefreshIndicator> createState() => _BrandRefreshIndicatorState();
}

class _BrandRefreshIndicatorState extends State<BrandRefreshIndicator> {
  RefreshIndicatorStatus? _status;

  bool get _showing =>
      _status != null &&
      _status != RefreshIndicatorStatus.done &&
      _status != RefreshIndicatorStatus.canceled;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        RefreshIndicator.noSpinner(
          onRefresh: widget.onRefresh,
          onStatusChange: (status) {
            if (mounted) setState(() => _status = status);
          },
          child: widget.child,
        ),
        Positioned(
          top: 14,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: Center(
              child: AnimatedOpacity(
                opacity: _showing ? 1 : 0,
                duration: const Duration(milliseconds: 160),
                child: _showing
                    ? const BrandLoader(size: 36)
                    : const SizedBox.square(dimension: 36),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
