import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/widgets/app_dialog.dart';
import 'package:professional_connections_platform/core/widgets/app_sheet.dart';

/// One tap, one dialog — the same guarantee `app_sheet_double_tap_test.dart`
/// asserts for sheets, for the nine confirmation dialogs (sign out, remove
/// contact, confirm rating, cancel/withdraw, close meetup, edit name).
///
/// A second copy of one of those is not a cosmetic double: it asks a
/// question the user has already answered, against a screen the first
/// answer already changed.
void main() {
  Future<BuildContext> pumpPage(WidgetTester tester) async {
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
    return pageContext;
  }

  testWidgets('two launches in the same frame open exactly one dialog', (
    tester,
  ) async {
    final page = await pumpPage(tester);

    // No frame between them: a second tap landing before the first
    // dialog's barrier exists to swallow it. Once the barrier is up the
    // tester refuses to deliver the tap at all, so a pump in between would
    // prove nothing about this guard.
    showAppDialog<void>(page, builder: (_) => const Text('dialog body'));
    showAppDialog<void>(page, builder: (_) => const Text('dialog body'));
    await tester.pumpAndSettle();

    expect(find.text('dialog body'), findsOneWidget);

    // And exactly one route to come back from.
    Navigator.of(page).pop();
    await tester.pumpAndSettle();
    expect(find.text('dialog body'), findsNothing);
  });

  testWidgets('dismissing it lets the next tap open one again', (tester) async {
    final page = await pumpPage(tester);

    showAppDialog<void>(page, builder: (_) => const Text('dialog body'));
    await tester.pumpAndSettle();
    Navigator.of(page).pop();
    await tester.pumpAndSettle();
    expect(find.text('dialog body'), findsNothing);

    // The guard must not be sticky: it reads the live route each time.
    showAppDialog<void>(page, builder: (_) => const Text('dialog body'));
    await tester.pumpAndSettle();
    expect(find.text('dialog body'), findsOneWidget);
  });

  testWidgets('a dialog raised from inside a sheet still opens — the guard '
      'reads the caller route, not "is anything modal open"', (tester) async {
    final page = await pumpPage(tester);

    late BuildContext sheetContext;
    showAppSheet<void>(
      page,
      builder: (context) {
        sheetContext = context;
        return const Text('sheet body');
      },
    );
    await tester.pumpAndSettle();

    showAppDialog<void>(
      sheetContext,
      builder: (_) => const Text('dialog body'),
    );
    await tester.pumpAndSettle();

    expect(find.text('dialog body'), findsOneWidget);
    expect(find.text('sheet body'), findsOneWidget);
  });
}
