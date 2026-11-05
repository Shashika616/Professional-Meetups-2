import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/fill_scroll_view.dart';
import 'package:professional_connections_platform/core/widgets/pressable.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  test('white text on a filled red button reads at 4.5:1', () {
    expect(_contrast(Colors.white, AppPalette.sos), greaterThanOrEqualTo(4.5));
  });

  testWidgets('a tappable card is announced as a button', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Pressable(onTap: () {}, child: const Text('Coffee at noon')),
      ),
    );
    expect(
      tester.getSemantics(find.byType(Pressable)),
      matchesSemantics(
        label: 'Coffee at noon',
        isButton: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('a page taller than the screen scrolls at large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(3)),
          child: Scaffold(
            body: FillScrollView(
              child: Column(
                children: [
                  const Spacer(),
                  for (var i = 0; i < 12; i++) const Text('A line of text'),
                  const Spacer(),
                  const Text('Continue'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Continue'),
      100,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('Continue').hitTestable(), findsOneWidget);
  });
}
