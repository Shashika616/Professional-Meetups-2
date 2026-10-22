import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/widgets/app_back_button.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/features/verification/widgets/verification_scaffold.dart';

/// Back-button consistency.
///
/// Most screens get Flutter's implicit `AppBar` back button, which is
/// already platform-correct. The screens that draw their own header had each
/// hardcoded an icon, and had drifted into two wrong answers: the iOS
/// chevron on Android (schedule flow, onboarding) and the Android arrow on
/// iOS (the map overlay). These tests pin that the shared control renders
/// the same glyph `AppBar` would, on each platform, so a custom header is
/// indistinguishable from a stock one.
void main() {
  /// What `AppBar`'s own implicit back button renders on this platform —
  /// measured rather than asserted, so this test cannot drift from Flutter.

  /// The path [AppBackButton] actually draws on [platform].
  Future<String> sharedBackIcon(
    WidgetTester tester,
    TargetPlatform platform,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        // Keyed by platform: without it a second pump in the same test
        // reuses the element tree and the first platform's glyph stays on
        // screen, which made this test pass for the wrong reason.
        home: Scaffold(key: ValueKey(platform), body: const AppBackButton()),
      ),
    );
    await tester.pumpAndSettle();
    final icon = tester.widget<AppIcon>(
      find.descendant(
        of: find.byType(AppBackButton),
        matching: find.byType(AppIcon),
      ),
    );
    return icon.path;
  }

  // The old version of this asserted AppBackButton drew the SAME glyph as
  // AppBar's implicit button. That premise is gone: the app draws its own
  // stroke set now and AppBar draws Material's font, so they cannot match
  // and should not. What still has to hold is that the shape is RIGHT for
  // the platform, which is what AppBar was standing in for.
  testWidgets('each platform gets its own back shape: a bare chevron on '
      'iOS, an arrow with a shaft on Android', (tester) async {
    final onIos = await sharedBackIcon(tester, TargetPlatform.iOS);
    final onAndroid = await sharedBackIcon(tester, TargetPlatform.android);

    expect(onIos, AppIcons.back);
    expect(onAndroid, AppIcons.arrowLeft);
    expect(
      onIos,
      isNot(onAndroid),
      reason:
          'collapsing both platforms onto one glyph is the regression this '
          'guards: it is invisible in a single-platform test run',
    );
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('and backButtonIconPath agrees with it on $platform', (
      tester,
    ) async {
      // The map overlay needs the glyph rather than the whole button, so the
      // two must not be able to disagree.
      late String fromHelper;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: Builder(
            builder: (context) {
              fromHelper = backButtonIconPath(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final shared = await sharedBackIcon(tester, platform);
      expect(fromHelper, shared);
    });
  }

  testWidgets('it is announced with the same label AppBar uses, not a '
      'hardcoded one', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AppBackButton())),
    );

    final button = tester.widget<IconButton>(find.byType(IconButton));
    final context = tester.element(find.byType(AppBackButton));
    expect(
      button.tooltip,
      MaterialLocalizations.of(context).backButtonTooltip,
      reason: 'the label should translate with the app, not be English only',
    );
  });

  testWidgets('with no handler it pops the route, respecting PopScope', (
    tester,
  ) async {
    var blockedPops = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PopScope(
                    canPop: false,
                    onPopInvokedWithResult: (didPop, _) {
                      if (!didPop) blockedPops++;
                    },
                    child: const Scaffold(body: AppBackButton()),
                  ),
                ),
              ),
              child: const Text('push'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(AppBackButton));
    await tester.pumpAndSettle();

    // maybePop, not pop: a flow that wants to intercept back gets to.
    expect(blockedPops, 1);
    expect(find.byType(AppBackButton), findsOneWidget);
  });
  // VerificationScaffold is the one shared by all four verification steps
  // (phone, personal email, corporate email, personal details), which is
  // why this is tested here once rather than four times: until 2026-10-08
  // it offered only "Skip for now" and no back control at all, so a user
  // who opened the wrong step had nothing to tap. Skipping a step is a
  // different decision from leaving it.
  group('VerificationScaffold', () {
    Widget scaffold({VoidCallback? onSkip}) => MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => VerificationScaffold(
                  icon: AppIcons.phone,
                  headline: 'Verify your phone',
                  onSkip: onSkip ?? () {},
                  child: const SizedBox.shrink(),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    testWidgets('offers a back control alongside Skip, not instead of it', (
      tester,
    ) async {
      await tester.pumpWidget(scaffold());
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(
        find.byType(AppBackButton),
        findsOneWidget,
        reason: 'no way back from a verification step but the system gesture',
      );
      expect(find.text('Skip for now'), findsOneWidget);
    });

    testWidgets('back leaves the step without taking the skip decision', (
      tester,
    ) async {
      var skipped = 0;
      await tester.pumpWidget(scaffold(onSkip: () => skipped++));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(AppBackButton));
      await tester.pumpAndSettle();

      expect(find.text('open'), findsOneWidget, reason: 'it did not go back');
      expect(
        skipped,
        0,
        reason: 'going back must not record a decision to skip the step',
      );
    });
  });
}
