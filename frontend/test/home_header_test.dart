import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/features/home/widgets/home_header.dart';
import 'package:professional_connections_platform/features/meetups/my_meetups_page.dart';

import 'support/fake_meetup_service.dart';

/// Both entry points (ADR-020 §1) deep-link into MyMeetupsPage's own
/// TabController rather than just opening the page on HOSTING and leaving
/// the tab to find — this is the part worth a dedicated widget test.
void main() {
  Widget wrap() => ProviderScope(
    overrides: [
      meetupServiceProvider.overrideWithValue(ImmediateMeetupService()),
    ],
    child: const MaterialApp(
      home: Scaffold(body: HomeHeader(userName: 'Ada Lovelace')),
    ),
  );

  testWidgets(
    'tapping "Your Meetings" opens MyMeetupsPage on the HOSTING tab',
    (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();

      await tester.tap(find.text('Your Meetings'));
      await tester.pumpAndSettle();

      final page = tester.widget<MyMeetupsPage>(find.byType(MyMeetupsPage));
      expect(page.initialTab, 0);
    },
  );

  testWidgets(
    'tapping "Requested Meetups" opens MyMeetupsPage on the REQUESTED tab',
    (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();

      await tester.tap(find.text('Requested Meetups'));
      await tester.pumpAndSettle();

      final page = tester.widget<MyMeetupsPage>(find.byType(MyMeetupsPage));
      expect(page.initialTab, 1);
    },
  );
}
