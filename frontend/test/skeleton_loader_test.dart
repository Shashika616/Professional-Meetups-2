import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';

/// [SkeletonLoader] is the one place the app decides what "still loading"
/// looks like, so both halves of it are pinned here: the delay that stops a
/// fast load from flashing a placeholder, and the shimmer that stops a slow
/// one from looking like a rendering glitch.
///
/// `flutter_test_config.dart` freezes the shimmer for the whole suite (a
/// repeating controller never lets `pumpAndSettle` finish). The animated
/// tests below turn it back on for themselves, which is why the animated
/// path is not left uncovered.
void main() {
  const child = SkeletonBox(width: 100, height: 10);

  Widget wrap(Widget w) => MaterialApp(home: Scaffold(body: w));

  group('the delay', () {
    testWidgets('paints nothing before the delay elapses', (tester) async {
      await tester.pumpWidget(wrap(const SkeletonLoader(child: child)));

      expect(find.byType(SkeletonBox), findsNothing);

      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byType(SkeletonBox),
        findsNothing,
        reason:
            'still inside the window — a load this fast needs no placeholder',
      );
    });

    testWidgets('paints once the delay elapses', (tester) async {
      await tester.pumpWidget(wrap(const SkeletonLoader(child: child)));

      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(SkeletonBox), findsOneWidget);
    });

    testWidgets(
      'a load that finishes inside the window never paints a placeholder at '
      'all — the flash this widget exists to remove',
      (tester) async {
        await tester.pumpWidget(wrap(const SkeletonLoader(child: child)));
        await tester.pump(const Duration(milliseconds: 100));

        // "Data arrived": the loader is replaced before its timer fires.
        await tester.pumpWidget(wrap(const Text('real content')));
        await tester.pump(const Duration(milliseconds: 500));

        expect(find.byType(SkeletonBox), findsNothing);
        expect(find.text('real content'), findsOneWidget);
        // No pending-timer failure at teardown proves the timer was
        // cancelled on dispose rather than left to fire into nothing.
      },
    );

    testWidgets('a zero delay paints immediately, for callers that want it', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(const SkeletonLoader(delay: Duration.zero, child: child)),
      );
      await tester.pump();

      expect(find.byType(SkeletonBox), findsOneWidget);
    });
  });

  group('the shimmer', () {
    tearDown(() => debugDisableShimmerAnimation = true);

    testWidgets('animates by default — a static grey block reads as a glitch, '
        'motion reads as loading', (tester) async {
      debugDisableShimmerAnimation = false;

      await tester.pumpWidget(wrap(const SkeletonLoader(child: child)));
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        find.byType(ShaderMask),
        findsOneWidget,
        reason: 'the sweep is painted as a shader over the placeholder',
      );

      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.binding.hasScheduledFrame,
        isTrue,
        reason: 'it must keep scheduling frames — that is what animating is',
      );
    });

    testWidgets(
      'one sweep covers the whole block rather than each box animating '
      'separately, which would read as noise',
      (tester) async {
        debugDisableShimmerAnimation = false;

        await tester.pumpWidget(
          wrap(
            const SkeletonLoader(
              child: Column(
                children: [
                  SkeletonBox(width: 100, height: 10),
                  SkeletonBox(width: 80, height: 10),
                  SkeletonBox(width: 60, height: 10),
                ],
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.byType(SkeletonBox), findsNWidgets(3));
        expect(
          find.byType(ShaderMask),
          findsOneWidget,
          reason: 'three boxes, one sweep',
        );
      },
    );

    testWidgets(
      'honours reduce-motion: the placeholder stays visible but stops moving',
      (tester) async {
        debugDisableShimmerAnimation = false;

        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: const Scaffold(body: SkeletonLoader(child: child)),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));

        expect(
          find.byType(SkeletonBox),
          findsOneWidget,
          reason: 'reduce-motion must not cost the user the placeholder',
        );
        expect(find.byType(ShaderMask), findsNothing);
      },
    );
  });

  group('both themes', () {
    tearDown(() => AppPalette.setMode(AppThemeMode.dark));

    testWidgets(
      'the placeholder tint is derived per theme, not hardcoded — the same '
      'flat colour would be invisible on one of the two backgrounds',
      (tester) async {
        Color tintFor(AppThemeMode mode) {
          AppPalette.setMode(mode);
          return AppPalette.textPrimary.withValues(
            alpha: mode == AppThemeMode.light ? 0.06 * 2.2 : 0.06,
          );
        }

        final dark = tintFor(AppThemeMode.dark);
        final light = tintFor(AppThemeMode.light);

        expect(
          dark,
          isNot(light),
          reason: 'a single hardcoded tint cannot serve both themes',
        );

        // And the widget really renders the current theme's value.
        AppPalette.setMode(AppThemeMode.light);
        await tester.pumpWidget(
          wrap(const SkeletonLoader(delay: Duration.zero, child: child)),
        );
        await tester.pump();

        final box = tester.widget<Container>(
          find.descendant(
            of: find.byType(SkeletonBox),
            matching: find.byType(Container),
          ),
        );
        final decoration = box.decoration! as BoxDecoration;
        expect(decoration.color, light);
      },
    );
  });
}
