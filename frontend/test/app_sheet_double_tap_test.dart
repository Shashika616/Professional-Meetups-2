import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/widgets/app_sheet.dart';

/// One tap, one sheet.
///
/// A second tap arriving before the first sheet has finished rising used to
/// push a second copy. On anything that acts on open — the SOS
/// confirmation, a rating — that means answering a question you already
/// answered, and dismissing the same sheet twice to get back.
void main() {
  testWidgets('two launches in the same frame open exactly one sheet', (
    tester,
  ) async {
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              pageContext = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );

    // Called twice with no frame between them, which is the real race: a
    // second tap that lands before the first sheet's barrier exists to
    // swallow it. (Once the barrier IS up Flutter blocks the tap itself —
    // the tester refuses to deliver it — so tapping twice with a pump in
    // between would prove nothing about this guard.)
    showAppSheet<void>(pageContext, builder: (_) => const Text('sheet body'));
    showAppSheet<void>(pageContext, builder: (_) => const Text('sheet body'));
    await tester.pumpAndSettle();

    expect(find.text('sheet body'), findsOneWidget);

    // And exactly one route to come back from: a second copy would leave
    // the user dismissing the same sheet twice.
    Navigator.of(pageContext).pop();
    await tester.pumpAndSettle();
    expect(find.text('sheet body'), findsNothing);
  });

  testWidgets('dismissing it lets the next tap open one again', (tester) async {
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              pageContext = context;
              return Center(
                child: ElevatedButton(
                  onPressed: () => showAppSheet<void>(
                    pageContext,
                    builder: (_) => const Text('sheet body'),
                  ),
                  child: const Text('open'),
                ),
              );
            },
          ),
        ),
      ),
    );

    showAppSheet<void>(pageContext, builder: (_) => const Text('sheet body'));
    await tester.pumpAndSettle();
    expect(find.text('sheet body'), findsOneWidget);

    Navigator.of(pageContext).pop();
    await tester.pumpAndSettle();
    expect(find.text('sheet body'), findsNothing);

    // The guard must not be sticky: it reads the live route each time.
    showAppSheet<void>(pageContext, builder: (_) => const Text('sheet body'));
    await tester.pumpAndSettle();
    expect(find.text('sheet body'), findsOneWidget);
  });
}
