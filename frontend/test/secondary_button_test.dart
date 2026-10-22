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
                      label: 'Cancel meetup',
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
              label: 'Cancel meetup',
              onPressed: null,
              color: Colors.red,
              borderColor: Colors.red,
            ),
          ),
        ),
      );

      final text = tester.widget<Text>(find.text('Cancel meetup'));
      expect(text.style?.color, Colors.red);
    });

    // Was `tester.widget<OutlinedButton>(...).onPressed == null`. The
    // 2026-10 redesign made SecondaryButton a filled pill built from a
    // GestureDetector rather than an OutlinedButton, and that assertion
    // was testing WHICH WIDGET was used, not what the button does. These
    // two test the contract instead, so the next restyle can't break them
    // without actually breaking the behaviour.
    testWidgets('onPressed null does not fire, and reads as disabled to '
        'assistive tech', (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const SecondaryButton(label: 'SKIP', onPressed: null),
                SecondaryButton(label: 'GO', onPressed: () => taps++),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.text('SKIP'));
      await tester.pump();
      expect(taps, 0, reason: 'a disabled button must not invoke anything');

      await tester.tap(find.text('GO'));
      await tester.pump();
      expect(taps, 1, reason: 'the enabled control still works');

      expect(
        tester.getSemantics(find.text('SKIP')),
        matchesSemantics(
          label: 'SKIP',
          isButton: true,
          hasEnabledState: true,
          // No isEnabled, and crucially no hasTapAction: a disabled
          // control must not be offered as actionable.
        ),
      );
      expect(
        tester.getSemantics(find.text('GO')),
        matchesSemantics(
          label: 'GO',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('a disabled button is visibly dimmed', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SecondaryButton(label: 'SKIP', onPressed: null)),
        ),
      );

      final opacity = tester.widget<Opacity>(
        find.ancestor(of: find.text('SKIP'), matching: find.byType(Opacity)),
      );
      expect(opacity.opacity, lessThan(1.0));
    });
  });
}
