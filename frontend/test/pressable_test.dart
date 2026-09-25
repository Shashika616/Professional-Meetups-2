import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/widgets/pressable.dart';

/// Plan 23: press feedback for whole-card tap targets. The point of the
/// widget is that something happens on pointer DOWN, so that is what these
/// assert on — not just that the tap still works.
void main() {
  // Paints, so it takes a hit test: `GestureDetector` defers to its child
  // by default and this widget deliberately does not change that, so a
  // zero-paint child would never be pressed at all — in the test or in the
  // app. Every real call site wraps a card that paints.
  const child = ColoredBox(
    color: Color(0xFF123456),
    child: SizedBox(width: 200, height: 100),
  );

  // Scoped to this widget's own subtree: MaterialApp's route machinery puts
  // a ScaleTransition of its own in the tree, and a bare byType finder would
  // happily measure that one instead.
  final scaleFinder = find.descendant(
    of: find.byType(Pressable),
    matching: find.byType(ScaleTransition),
  );

  /// The scale actually being applied to the child right now.
  double currentScale(WidgetTester tester) {
    expect(
      scaleFinder,
      findsOneWidget,
      reason: 'AnimatedScale renders through a ScaleTransition',
    );
    return tester.widget<ScaleTransition>(scaleFinder).scale.value;
  }

  Widget app(Widget pressable, {bool disableAnimations = false}) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(body: Center(child: pressable)),
    ),
  );

  testWidgets('pressing down shrinks the child, and releasing restores it', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      app(Pressable(onTap: () => taps++, child: child)),
    );

    expect(currentScale(tester), 1.0);

    final gesture = await tester.press(find.byType(Pressable));
    await tester.pumpAndSettle();
    expect(
      currentScale(tester),
      lessThan(1.0),
      reason: 'feedback must start on pointer-down, not on release',
    );
    expect(currentScale(tester), closeTo(0.98, 0.001));
    expect(taps, 0, reason: 'nothing has been released yet');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(currentScale(tester), 1.0);
    expect(taps, 1);
  });

  testWidgets('a cancelled press (finger dragged away) springs back and does '
      'not fire onTap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      app(Pressable(onTap: () => taps++, child: child)),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(Pressable)),
    );
    await tester.pumpAndSettle();
    expect(currentScale(tester), closeTo(0.98, 0.001));

    // Off the widget entirely, then release: GestureDetector's own
    // tap-commit rule, which this widget deliberately does not change.
    await gesture.moveTo(const Offset(5, 5));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(currentScale(tester), 1.0);
    expect(taps, 0);
  });

  testWidgets('a disabled Pressable neither animates nor fires', (
    tester,
  ) async {
    await tester.pumpWidget(app(const Pressable(onTap: null, child: child)));

    final gesture = await tester.press(find.byType(Pressable));
    await tester.pumpAndSettle();
    expect(
      currentScale(tester),
      1.0,
      reason: 'a dead card must not animate as though it were about to act',
    );
    await gesture.up();
    await tester.pump();
  });

  testWidgets('honours reduce-motion: the tap still works, the scale never '
      'changes', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      app(
        Pressable(onTap: () => taps++, child: child),
        disableAnimations: true,
      ),
    );

    // No AnimatedScale in the tree at all, the same early return Shimmer
    // makes (skeleton_loader_test.dart asserts its ShaderMask the same way).
    expect(scaleFinder, findsNothing);

    final gesture = await tester.press(find.byType(Pressable));
    await tester.pumpAndSettle();
    expect(scaleFinder, findsNothing);

    await gesture.up();
    await tester.pump();
    expect(taps, 1, reason: 'reduce-motion must not cost the user the tap');
  });
}
