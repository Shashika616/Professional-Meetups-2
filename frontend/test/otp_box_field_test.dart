import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/widgets/otp_box_field.dart';

Widget _harness(TextEditingController controller) {
  return MaterialApp(
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: OtpBoxField(controller: controller),
      ),
    ),
  );
}

void main() {
  testWidgets('renders one box per digit', (tester) async {
    await tester.pumpWidget(_harness(TextEditingController()));
    await tester.pumpAndSettle();

    // The screen used to be a single wide field with a '######' hint.
    expect(find.byType(AnimatedContainer), findsNWidgets(6));
  });

  testWidgets('typed digits land in the boxes left to right', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '482');
    await tester.pump();

    expect(find.text('4'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    // The remaining three stay empty rather than showing placeholders.
    expect(find.text('#'), findsNothing);
  });

  testWidgets('the caller\'s controller is the single source of truth — the '
      'widget keeps no code state of its own', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    expect(controller.text, '123456');

    // This is what OtpEntry does when the server rejects a code. If the
    // boxes held their own copy they would still show the old digits.
    controller.clear();
    await tester.pump();
    expect(find.text('1'), findsNothing);
    expect(find.text('6'), findsNothing);
  });

  testWidgets('non-digits are rejected and the code cannot exceed 6', (
    tester,
  ) async {
    final controller = TextEditingController();
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '12a3b4');
    await tester.pump();
    expect(controller.text, '1234');

    await tester.enterText(find.byType(TextField), '123456789');
    await tester.pump();
    expect(controller.text, '123456');
  });

  testWidgets('a pasted code fills every box at once', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    // Six separate fields would have taken only the first character here —
    // which is the main reason this is one hidden field.
    await tester.enterText(find.byType(TextField), '908172');
    await tester.pump();

    expect(controller.text, '908172');
    for (final digit in ['9', '0', '8', '1', '7', '2']) {
      expect(find.text(digit), findsWidgets);
    }
  });

  testWidgets('the field offers the OS one-time-code autofill hint', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(TextEditingController()));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.autofillHints, contains(AutofillHints.oneTimeCode));
  });
}
