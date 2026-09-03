import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/main.dart';

/// Throws a distinctive, unique string in its build method — if this string
/// (or any part of the raw exception) ever shows up in the rendered
/// widget tree, the friendly error widget has a leak.
class _ThrowingWidget extends StatelessWidget {
  const _ThrowingWidget();

  @override
  Widget build(BuildContext context) {
    throw StateError('super-secret-internal-stack-trace-detail-12345');
  }
}

void main() {
  testWidgets(
    'buildFriendlyErrorWidget never renders the raw exception message — '
    'a real user must only ever see the clean fallback copy',
    (tester) async {
      final previousBuilder = ErrorWidget.builder;
      ErrorWidget.builder = buildFriendlyErrorWidget;
      addTearDown(() => ErrorWidget.builder = previousBuilder);

      // Flutter's test framework treats a build-time exception as a fatal
      // test failure by default (takeException) — silence that reporting
      // path so this test can actually assert on the *rendered fallback*
      // instead of the framework auto-failing on the caught exception.
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) {};
      addTearDown(() => FlutterError.onError = originalOnError);

      await tester.pumpWidget(const MaterialApp(home: _ThrowingWidget()));

      // The clean, user-safe fallback is shown...
      expect(find.text('Something went wrong.'), findsOneWidget);
      expect(
        find.text('Please try again. If this keeps happening, let us know.'),
        findsOneWidget,
      );

      // ...and the raw exception detail is nowhere in the widget tree.
      expect(
        find.textContaining('super-secret-internal-stack-trace-detail'),
        findsNothing,
      );
      expect(find.textContaining('StateError'), findsNothing);
    },
  );
}
