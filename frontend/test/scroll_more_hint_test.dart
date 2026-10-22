import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/widgets/app_icons.dart';

import 'package:professional_connections_platform/core/widgets/scroll_more_hint.dart';

import 'support/app_icon_finder.dart';

/// The "more below" chevron. What matters is that it tells the truth: it
/// appears only when there is something below, and goes away at the end —
/// a hint that lies is worse than no hint, because it is the only thing
/// saying whether a list between a fixed header and pinned buttons has
/// run out.
void main() {
  Widget harness({required int rows, ScrollController? controller}) {
    final c = controller ?? ScrollController();
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 400,
          child: Stack(
            children: [
              ListView.builder(
                controller: c,
                itemCount: rows,
                itemBuilder: (_, i) =>
                    SizedBox(height: 100, child: Text('row $i')),
              ),
              ScrollMoreHint(controller: c),
            ],
          ),
        ),
      ),
    );
  }

  double opacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(
        find.descendant(
          of: find.byType(ScrollMoreHint),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  testWidgets('shows when the list runs past the bottom', (tester) async {
    await tester.pumpWidget(harness(rows: 20));
    await tester.pumpAndSettle();

    expect(opacity(tester), 1.0);
  });

  testWidgets('stays hidden when everything already fits', (tester) async {
    // Three 100px rows in a 400px viewport: nothing to scroll to.
    await tester.pumpWidget(harness(rows: 3));
    await tester.pumpAndSettle();

    expect(
      opacity(tester),
      0.0,
      reason: 'a chevron pointing at nothing is worse than none',
    );
  });

  testWidgets('goes away once the end is reached, and comes back on the way '
      'up', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(harness(rows: 20, controller: controller));
    await tester.pumpAndSettle();
    expect(opacity(tester), 1.0);

    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(opacity(tester), 0.0);

    controller.jumpTo(0);
    await tester.pumpAndSettle();
    expect(opacity(tester), 1.0);
  });

  testWidgets('tapping it pages down', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(harness(rows: 20, controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(findAppIcon(AppIcons.chevronDown));
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(0));
  });
}
