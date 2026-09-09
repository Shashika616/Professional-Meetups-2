import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/subscription_service.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/features/notifications/notifications_page.dart';
import 'package:professional_connections_platform/features/premium/premium_page.dart';
import 'package:professional_connections_platform/features/privacy/privacy_controls_page.dart';
import 'package:professional_connections_platform/features/safety/safety_page.dart';

import 'support/scripted_meetup_service.dart';

/// Pages pushed as their own route paint their own background — nothing
/// above them does. Premium and Safety Center were missing it and rendered
/// as flat black/white panels next to every other screen in the app; the two
/// new pages must not repeat that.
void main() {
  Widget wrap(Widget page) => ProviderScope(
    overrides: [
      meetupServiceProvider.overrideWithValue(ScriptedMeetupService()),
      subscriptionStatusProvider.overrideWith(
        (ref) async => const SubscriptionStatus(
          tier: SubscriptionTier.free,
          status: SubscriptionLifecycleStatus.none,
        ),
      ),
    ],
    child: MaterialApp(home: page),
  );

  for (final entry in <String, Widget>{
    'PremiumPage': const PremiumPage(),
    'SafetyPage': const SafetyPage(),
    'PrivacyControlsPage': const PrivacyControlsPage(),
    'NotificationsPage': const NotificationsPage(),
  }.entries) {
    testWidgets('${entry.key} paints the app background', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(entry.value));
      await tester.pump();

      expect(find.byType(AppBackground), findsWidgets);

      // extendBodyBehindAppBar, so the (transparent) app bar sits over the
      // background rather than as a flat band above it.
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(
        scaffold.extendBodyBehindAppBar,
        isTrue,
        reason: '${entry.key} leaves an unpainted strip behind its app bar',
      );
      expect(scaffold.backgroundColor, Colors.transparent);
    });
  }

  // extendBodyBehindAppBar is what lets AppBackground paint the app-bar
  // strip — but it also means the body starts at y=0, UNDER the bar and the
  // status bar. A SafeArea in the body is what pushes content back below
  // them (the bar's height is folded into MediaQuery's top padding).
  //
  // Without it the page renders its first row over the clock and the title,
  // which is exactly what Safety Center did after gaining the flag.
  for (final entry in <String, Widget>{
    'PremiumPage': const PremiumPage(),
    'SafetyPage': const SafetyPage(),
    'PrivacyControlsPage': const PrivacyControlsPage(),
    'NotificationsPage': const NotificationsPage(),
  }.entries) {
    testWidgets('${entry.key} keeps its content clear of the app bar', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(entry.value));
      await tester.pumpAndSettle();

      // The declared pairing: the flag and the SafeArea go together.
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      if (!scaffold.extendBodyBehindAppBar) return;
      expect(
        find.descendant(
          of: find.byType(Scaffold).first,
          matching: find.byType(SafeArea),
        ),
        findsWidgets,
        reason:
            '${entry.key} extends its body behind the app bar with no '
            'SafeArea, so its content renders over the title and the clock',
      );

      // And the geometry that actually matters: nothing painted above the
      // app bar's bottom edge.
      final appBarBottom = tester.getRect(find.byType(AppBar)).bottom;
      final firstText = find.byType(Text);
      expect(firstText, findsWidgets);
      for (final element in firstText.evaluate()) {
        final rect = tester.getRect(find.byWidget(element.widget));
        // The AppBar's own title is legitimately inside that band.
        final insideAppBar = find
            .ancestor(
              of: find.byWidget(element.widget),
              matching: find.byType(AppBar),
            )
            .evaluate()
            .isNotEmpty;
        if (insideAppBar || rect.isEmpty) continue;
        expect(
          rect.top,
          greaterThanOrEqualTo(appBarBottom - 1),
          reason:
              '${entry.key}: "${(element.widget as Text).data}" is drawn at '
              'y=${rect.top}, above the app bar bottom ($appBarBottom)',
        );
      }
    });
  }
}
