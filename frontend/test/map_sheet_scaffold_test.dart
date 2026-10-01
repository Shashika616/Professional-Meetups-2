import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/maps/map_sheet_scaffold.dart';

/// The layout behind all three map screens. What is worth pinning is the
/// one thing it exists to get right: the map runs edge to edge, INCLUDING
/// behind the panel, while the pin sits in the middle of the part you can
/// actually see. Centring the pin in the full area instead is the bug that
/// makes a picker feel wrong — you drag a place under the pin and submit a
/// point that is somewhere else.
void main() {
  group('the system navigation bar', _navBarGroup);

  const mapKey = Key('map');
  const pinKey = Key('pin');
  const sheetKey = Key('sheet');

  Widget harness({double sheetHeight = 200, Widget? overlay}) => MaterialApp(
    home: Scaffold(
      body: MapSheetScaffold(
        map: const ColoredBox(key: mapKey, color: Color(0xFF102030)),
        centrePin: const SizedBox(key: pinKey, width: 10, height: 10),
        sheet: SizedBox(key: sheetKey, height: sheetHeight),
        overlay: overlay,
      ),
    ),
  );

  testWidgets('the map fills the whole area, panel included', (tester) async {
    await tester.pumpWidget(harness());

    final screen = tester.getRect(find.byType(MapSheetScaffold));
    expect(
      tester.getRect(find.byKey(mapKey)),
      screen,
      reason: 'a map stopping above the panel reads as a box beside it',
    );
  });

  testWidgets('the pin centres in the VISIBLE map, not the full area', (
    tester,
  ) async {
    const sheetHeight = 200.0;
    await tester.pumpWidget(harness(sheetHeight: sheetHeight));

    final screen = tester.getRect(find.byType(MapSheetScaffold));
    final pin = tester.getCenter(find.byKey(pinKey));
    final visibleCentre = (screen.height - sheetHeight) / 2;

    expect(pin.dy, closeTo(visibleCentre, 0.5));
    expect(
      pin.dy,
      lessThan(screen.center.dy),
      reason: 'centring in the full area would put it behind the panel',
    );
  });

  testWidgets('a taller panel pushes the pin up, with no measurement pass', (
    tester,
  ) async {
    await tester.pumpWidget(harness(sheetHeight: 120));
    final shortPanel = tester.getCenter(find.byKey(pinKey)).dy;

    // One pump, not pumpAndSettle: the geometry is plain layout, so it is
    // right on the first frame rather than after a post-frame correction.
    await tester.pumpWidget(harness(sheetHeight: 320));
    final tallPanel = tester.getCenter(find.byKey(pinKey)).dy;

    expect(tallPanel, lessThan(shortPanel));
  });

  testWidgets('the panel sits on the bottom edge', (tester) async {
    await tester.pumpWidget(harness());

    final screen = tester.getRect(find.byType(MapSheetScaffold));
    expect(
      tester.getRect(find.byKey(sheetKey)).bottom,
      closeTo(screen.bottom, 0.5),
    );
  });

  testWidgets('an overlay covers the panel too, so nothing behind it is '
      'reachable', (tester) async {
    const overlayKey = Key('overlay');
    await tester.pumpWidget(
      harness(
        overlay: const ColoredBox(key: overlayKey, color: Color(0x80000000)),
      ),
    );

    final screen = tester.getRect(find.byType(MapSheetScaffold));
    expect(
      tester.getRect(find.byKey(overlayKey)),
      screen,
      reason:
          'an open suggestions list must cover the CONTINUE button under it',
    );
  });
}

/// The system navigation bar, which is only real on an edge-to-edge device
/// (Android 15 forces it for apps targeting SDK 35+, as this one does). It
/// cannot be seen on the API 34 emulator, where every inset is zero, so it
/// is pinned here instead.
///
/// Both assertions measure the sheet's OWN bottom padding — the gap under
/// its last child — because that is the thing the inset feeds. Measuring
/// the sheet's height instead just measures whatever a wrapping SafeArea
/// did, which is true either way and proves nothing.
void _navBarGroup() {
  const inset = EdgeInsets.only(bottom: 48);

  Widget sheetUnder({required bool insideSafeArea}) {
    const sheet = MapSheet(
      children: [SizedBox(key: Key('action'), height: 50)],
    );
    return MediaQuery(
      data: const MediaQueryData(padding: inset, viewPadding: inset),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          // Bottom-aligned and intrinsically sized, so the measurement is
          // the sheet's own padding rather than the whole test surface.
          alignment: Alignment.bottomCenter,
          child: insideSafeArea ? const SafeArea(child: sheet) : sheet,
        ),
      ),
    );
  }

  double gapUnderAction(WidgetTester tester) =>
      tester.getRect(find.byType(MapSheet)).bottom -
      tester.getRect(find.byKey(const Key('action'))).bottom;

  testWidgets('clears the navigation bar when nothing else has', (
    tester,
  ) async {
    await tester.pumpWidget(sheetUnder(insideSafeArea: false));

    expect(
      gapUnderAction(tester),
      greaterThanOrEqualTo(48),
      reason: 'the button would sit under the navigation bar',
    );
  });

  testWidgets('does not count it twice inside a SafeArea', (tester) async {
    await tester.pumpWidget(sheetUnder(insideSafeArea: true));

    expect(
      gapUnderAction(tester),
      lessThan(48),
      reason:
          'a SafeArea already moved the sheet up and zeroes BOTH padding '
          'and viewPadding for what is inside it (measured, not assumed), '
          'so the sheet must read zero here; anything that adds the inset '
          'a second time floats a dead gap under the button',
    );
  });
}
