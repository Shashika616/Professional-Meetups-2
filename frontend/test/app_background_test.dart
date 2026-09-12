import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/widgets/app_background.dart';

/// [AppBackground] paints once, however many times it is nested.
///
/// # WHY THIS MATTERS BEYOND TIDINESS
///
/// Each painted instance is a full-screen `Image.asset` under an `Opacity`
/// and a `ColorFiltered` — both of which force an off-screen `saveLayer` over
/// the whole screen. `EventsPage` wrapped itself in one while already inside
/// `AppShell`'s, so the Events tab composited two of those every frame of a
/// page transition and held two independent image streams for the same
/// asset. The layer paints a flat `AppPalette.onyx` fill first and the image
/// renders nothing until its stream resolves, so each un-resolved stream is a
/// plain grey panel — two chances to show one.
///
/// The pass-through must NOT break the pushed-route case: `EventsPage` is
/// also pushed as a route by `meetup_detail_page.dart`, and a pushed route is
/// built under the `Navigator`, above `AppShell`, so it has no background
/// ancestor and must still paint its own.
void main() {
  int paintedLayers() =>
      find.byKey(AppBackground.layerKey, skipOffstage: false).evaluate().length;

  testWidgets('a single AppBackground paints one layer', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: AppBackground(child: Text('content'))),
    );

    expect(paintedLayers(), 1);
    expect(find.text('content'), findsOneWidget);
  });

  testWidgets(
    'a NESTED AppBackground paints nothing extra — the redundancy that made '
    'the Events tab composite two full-screen saveLayers per frame',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: AppBackground(child: AppBackground(child: Text('content'))),
        ),
      );

      expect(
        paintedLayers(),
        1,
        reason: 'the inner one must pass through, not paint a second time',
      );
      // The child still renders — a pass-through, not a drop.
      expect(find.text('content'), findsOneWidget);
    },
  );

  testWidgets('nesting three deep still paints exactly one', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AppBackground(
          child: AppBackground(child: AppBackground(child: Text('content'))),
        ),
      ),
    );

    expect(paintedLayers(), 1);
    expect(find.text('content'), findsOneWidget);
  });

  testWidgets(
    'a PUSHED route still paints its own — routes are built under the '
    'Navigator, above the page that pushed them, so they genuinely have no '
    'background ancestor',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AppBackground(
            child: Builder(
              builder: (context) => Scaffold(
                backgroundColor: Colors.transparent,
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            const AppBackground(child: Text('pushed')),
                      ),
                    ),
                    child: const Text('PUSH'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(paintedLayers(), 1);

      await tester.tap(find.text('PUSH'));
      await tester.pumpAndSettle();

      expect(find.text('pushed'), findsOneWidget);
      expect(
        paintedLayers(),
        2,
        reason:
            'the pushed route has no AppBackground ancestor and must paint '
            'its own, or it renders on plain black',
      );
    },
  );

  // The regression that shipped on 2026-09-10: replacing the photo Stack with
  // a plain `Container(color:, child:)` made the ground size to its CHILD.
  // Pages whose content fills the viewport looked fine; the email sign-in
  // step, whose content is short, painted its ground for the top half and let
  // the rest fall through to bare black.
  //
  // Asserts the painted layer covers the whole viewport with deliberately
  // tiny content - the only shape that catches it.
  testWidgets('the ground fills the viewport even when the content is short', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: AppBackground(child: SizedBox(height: 40, child: Text('x'))),
        ),
      ),
    );

    final layer = tester.getSize(
      find.byKey(AppBackground.layerKey, skipOffstage: false),
    );
    expect(
      layer.height,
      900,
      reason: 'the ground must cover the viewport, not just the content',
    );
    expect(layer.width, 400);
  });
}
