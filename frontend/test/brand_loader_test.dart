import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/widgets/brand_loader.dart';

void main() {
  testWidgets('it loops, and is announced as loading', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: BrandLoader())),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.hasRunningAnimations, isTrue);
    expect(find.bySemanticsLabel('Loading'), findsOneWidget);
  });

  testWidgets('reduce motion holds the finished mark still', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: BrandLoader())),
    );
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('pull to refresh shows it, then takes it away', (tester) async {
    var refreshed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrandRefreshIndicator(
            onRefresh: () async {
              refreshed++;
              await Future<void>.delayed(const Duration(seconds: 2));
            },
            child: ListView(
              children: const [SizedBox(height: 900, child: Text('list'))],
            ),
          ),
        ),
      ),
    );
    expect(find.byType(BrandLoader), findsNothing);
    await tester.fling(find.text('list'), const Offset(0, 400), 1000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 400));
    expect(refreshed, 1);
    expect(find.byType(BrandLoader), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(BrandLoader), findsNothing);
  });

  test('nothing in the app uses the circular spinner any more', () {
    final found = [
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File &&
            file.path.endsWith('.dart') &&
            file.readAsStringSync().contains('CircularProgressIndicator('))
          file.path,
    ];
    expect(found, isEmpty);
  });
}
