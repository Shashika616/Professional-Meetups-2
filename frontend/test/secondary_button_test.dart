import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/widgets/secondary_button.dart';

void main() {
  group('SecondaryButton overflow regression — unifies every OutlinedButton '
      'call site (DIDN\'T HAPPEN, REJECT, SKIP, CLOSE/CANCEL MEETUP) on the '
      'same non-truncating behavior as PrimaryButton', () {
    testWidgets(
      'a long label on a narrow device does not overflow, and renders in '
      'full rather than ellipsized/cut off',
      (tester) async {
        tester.view.physicalSize = const Size(200, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        const longLabel = "DIDN'T HAPPEN";
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  Expanded(
                    child: SecondaryButton(
                      label: longLabel,
                      height: 42,
                      onPressed: null,
                    ),
                  ),
                  Expanded(
                    child: SecondaryButton(
                      label: 'CANCEL MEETUP',
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
        expect(find.text(longLabel), findsOneWidget);
        expect(find.byType(FittedBox), findsWidgets);
        final label = tester.widget<Text>(find.text(longLabel));
        expect(label.overflow, isNot(TextOverflow.ellipsis));
      },
    );

    testWidgets('color and borderColor override the defaults (used for '
        'the danger-styled CANCEL MEETUP button)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SecondaryButton(
              label: 'CANCEL MEETUP',
              onPressed: null,
              color: Colors.red,
              borderColor: Colors.red,
            ),
          ),
        ),
      );

      final text = tester.widget<Text>(find.text('CANCEL MEETUP'));
      expect(text.style?.color, Colors.red);
    });

    testWidgets('onPressed null disables the button', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SecondaryButton(label: 'SKIP', onPressed: null)),
        ),
      );

      final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
      expect(button.onPressed, isNull);
    });
  });
}
