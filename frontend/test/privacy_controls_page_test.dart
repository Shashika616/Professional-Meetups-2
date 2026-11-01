import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/analytics/analytics.dart';
import 'package:professional_connections_platform/core/analytics/event_names.g.dart';
import 'package:professional_connections_platform/features/privacy/privacy_controls_page.dart';

import 'support/analytics_harness.dart';

void main() {
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: PrivacyControlsPage()));
    await tester.pumpAndSettle();
  }

  testWidgets('lists each thing the app does with your data', (tester) async {
    await pumpPage(tester);
    for (final title in [
      'Who can see you',
      'Your location',
      'Trusted contacts',
      'Searching for a place',
      'Ratings you give',
    ]) {
      expect(find.text(title), findsOneWidget, reason: 'missing "$title"');
    }
  });

  // Each fact is collapsed until tapped.
  Future<void> open(WidgetTester tester, String title) async {
    await tester.ensureVisible(find.text(title));
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  // #94: place search sends what you type to outside services. The policy
  // has to name them, on both platforms.
  testWidgets('names every service a place search reaches', (tester) async {
    await pumpPage(tester);
    await open(tester, 'Searching for a place');
    for (final service in ['Apple Maps', 'Photon by komoot', 'Nominatim']) {
      expect(
        find.textContaining(service),
        findsOneWidget,
        reason: '"$service" is not disclosed',
      );
    }
  });

  // #80: adding a contact now texts them once. The page used to say nobody
  // contacts them but you, which stopped being true.
  testWidgets('says a new trusted contact is texted once to agree', (
    tester,
  ) async {
    await pumpPage(tester);
    await open(tester, 'Trusted contacts');
    expect(
      find.textContaining('we text them once to ask whether they agree'),
      findsOneWidget,
    );
  });

  // Plan 29E: the first real control replaces "Controls are coming".
  testWidgets('the analytics switch is real: off clears, stops and tells the '
      'server; on starts again', (tester) async {
    final transport = FakeAnalyticsTransport();
    final analytics = await installTestAnalytics(transport: transport);
    analytics.cta(AnalyticsCta.openMap);
    await pumpPage(tester);
    expect(find.text('Controls are coming'), findsNothing);
    expect(find.text('Share usage analytics'), findsOneWidget);
    final toggle = find.byKey(const Key('analyticsToggle'));
    await tester.ensureVisible(toggle);
    expect(
      tester.widget<Switch>(toggle).value,
      isTrue,
      reason: 'on by default',
    );

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isFalse);
    expect(Analytics.instance.optedOut, isTrue);
    expect(analytics.queue.isEmpty, isTrue);
    expect(transport.consents, [true]);
    analytics.cta(AnalyticsCta.openMap);
    expect(analytics.queue.isEmpty, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(Analytics.instance.optedOut, isFalse);
    expect(transport.consents, [true, false]);
  });
}
