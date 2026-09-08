import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/features/home/widgets/intent_filter_bar.dart';

/// Surfaces must be OPAQUE, in both themes.
///
/// # WHAT THIS IS GUARDING
///
/// Nine components asked for a subtle accent by passing a 6–15% alpha colour
/// as a card's fill. `FlatCard` assigned that straight to `color`, which does
/// not tint a card — it makes the card 85–94% transparent, so
/// `AppBackground`'s photo showed through every one of them. That is what
/// read as unfinished "glass", and it was worst on the light theme, where a
/// dark desaturated photo sits behind near-white surfaces.
///
/// The accents are unchanged; they are composited onto the card instead of
/// replacing it. These tests exist because the difference is invisible in a
/// code review — both versions are "a colour with an alpha" — and shows up
/// only on a device.
void main() {
  tearDown(() => AppPalette.setMode(AppThemeMode.dark));

  Color fillOf(WidgetTester tester, Finder container) {
    final decoration =
        tester.widget<Container>(container).decoration! as BoxDecoration;
    return decoration.color!;
  }

  for (final mode in AppThemeMode.values) {
    final themeName = mode == AppThemeMode.light ? 'light' : 'dark';

    group('$themeName theme', () {
      testWidgets('an untinted FlatCard is fully opaque', (tester) async {
        AppPalette.setMode(mode);
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: FlatCard(child: Text('x'))),
          ),
        );

        final fill = fillOf(
          tester,
          find.descendant(
            of: find.byType(FlatCard),
            matching: find.byType(Container),
          ),
        );
        expect(fill.a, 1.0);
      });

      testWidgets(
        'a TINTED FlatCard is still fully opaque — the accent is painted onto '
        'the card, not through it',
        (tester) async {
          AppPalette.setMode(mode);
          final tint = AppPalette.danger.withValues(alpha: 0.08);

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: FlatCard(tint: tint, child: const Text('x')),
              ),
            ),
          );

          final fill = fillOf(
            tester,
            find.descendant(
              of: find.byType(FlatCard),
              matching: find.byType(Container),
            ),
          );

          expect(
            fill.a,
            1.0,
            reason:
                'an 8% alpha fill would leave the card 92% transparent and '
                'show the background photo through it',
          );
          expect(
            fill,
            isNot(AppPalette.card),
            reason: 'but it must still read as tinted, not as a plain card',
          );
        },
      );

      testWidgets('intent filter chips are opaque in both states', (
        tester,
      ) async {
        AppPalette.setMode(mode);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: IntentFilterBar(
                selected: IntentType.coffee,
                trustLevel: 4,
                onSelect: (_) {},
              ),
            ),
          ),
        );
        await tester.pump();

        final containers = find.descendant(
          of: find.byType(IntentFilterBar),
          matching: find.byType(Container),
        );
        expect(containers, findsWidgets);

        for (final element in containers.evaluate()) {
          final decoration =
              (element.widget as Container).decoration as BoxDecoration?;
          final color = decoration?.color;
          if (color == null) continue;
          expect(
            color.a,
            1.0,
            reason:
                'a chip fill must not be translucent — the unselected one was '
                'a hardcoded 4% white, invisible on the light theme',
          );
        }
      });
    });
  }

  test('tintedSurface keeps the accent but removes the transparency', () {
    for (final mode in AppThemeMode.values) {
      AppPalette.setMode(mode);
      final accent = AppPalette.candyBlue.withValues(alpha: 0.12);
      final result = AppPalette.tintedSurface(accent);

      expect(result.a, 1.0);
      expect(
        result,
        isNot(AppPalette.card),
        reason: 'a tint that produced the plain card colour would be a no-op',
      );
    }
  });

  test('the glass vocabulary is gone from the palette', () {
    // `glassTint` existed only for a translucent surface treatment the app no
    // longer has; `glassBorder` became `hairline`, which is what a 1px
    // separator actually is. This is a compile-time guarantee — the test
    // exists to state the intent, since a reintroduced token would otherwise
    // only be caught in review.
    expect(AppPalette.hairline, isA<Color>());
  });
}
