import 'package:flutter_test/flutter_test.dart';
import 'package:professional_connections_platform/core/widgets/brand_loader.dart';

void main() {
  test('the loop starts empty', () {
    final frame = brandLoaderFrame(0);
    expect([frame.blue, frame.green, frame.fill], [0, 0, 0]);
  });

  test('blue draws first, then green, then the mark fills', () {
    final blueOnly = brandLoaderFrame(0.1);
    expect(blueOnly.blue, greaterThan(0));
    expect(blueOnly.green, 0);

    final greenDrawing = brandLoaderFrame(0.28);
    expect(greenDrawing.blue, 1);
    expect(greenDrawing.green, inExclusiveRange(0, 1));
    expect(greenDrawing.fill, 0);

    final finished = brandLoaderFrame(0.5);
    expect([finished.blue, finished.green, finished.fill], [1, 1, 1]);
  });

  test('the second half is the first played backwards', () {
    for (final t in [0.1, 0.2, 0.3, 0.4]) {
      final back = brandLoaderFrame(1 - t), forth = brandLoaderFrame(t);
      expect(back.blue, closeTo(forth.blue, 1e-3));
      expect(back.green, closeTo(forth.green, 1e-3));
      expect(back.fill, closeTo(forth.fill, 1e-3));
    }
  });
}
