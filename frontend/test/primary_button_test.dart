import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/widgets/primary_button.dart';

void main() {
  group('PrimaryButton overflow regression (ADR-016)', () {
    // Reproduces the exact reported RenderFlex-overflowed-by-16-pixels bug:
    // a bold, letter-spaced label ("IT HAPPENED") inside a PrimaryButton,
    // half-width in a Row on an iPhone-SE-class (~375 logical px) device —
    // the real layout meetup_detail_page.dart's "How did it go?" section
    // uses (PrimaryButton + a plain OutlinedButton, each Expanded, side by
    // side), not two PrimaryButtons — the fix is at the PrimaryButton
    // widget level regardless, since the overflow originates inside its own
    // Row/Text, not from what sits next to it.
    testWidgets('a long label on a narrow device does not overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: PrimaryButton(
                      label: 'IT HAPPENED',
                      height: 42,
                      onPressed: null,
                    ),
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: PrimaryButton(
                      label: "DIDN'T HAPPEN",
                      height: 42,
                      onPressed: null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'the full label still renders — shrunk to fit via FittedBox, not '
      'ellipsized/truncated (the "IT HAPPE..." bug reported on iOS: the '
      'earlier TextOverflow.ellipsis fix stopped the crash but visibly cut '
      'the label off on a narrow-enough device)',
      (tester) async {
        tester.view.physicalSize = const Size(200, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        const longLabel = 'A SIGNIFICANTLY LONGER LABEL THAN USUAL';
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  Expanded(
                    child: PrimaryButton(
                      label: longLabel,
                      height: 42,
                      onPressed: null,
                    ),
                  ),
                  Expanded(
                    child: PrimaryButton(
                      label: 'ANOTHER LONG LABEL HERE TOO',
                      height: 42,
                      onPressed: null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        // The full string is still there, verbatim — nothing got cut down
        // to "A SIGNIFICANTLY..." or similar.
        expect(find.text(longLabel), findsOneWidget);
        expect(find.byType(FittedBox), findsWidgets);
        final label = tester.widget<Text>(find.text(longLabel));
        expect(
          label.overflow,
          isNot(TextOverflow.ellipsis),
          reason: 'shrinking, not ellipsizing, is what fixed the bug',
        );
      },
    );
  });
}
