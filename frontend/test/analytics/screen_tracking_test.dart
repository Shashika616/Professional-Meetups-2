import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/analytics/analytics.dart';
import 'package:professional_connections_platform/core/analytics/event_names.g.dart';
import 'package:professional_connections_platform/core/analytics/screen_names.dart';
import 'package:professional_connections_platform/core/analytics/screen_tracker.dart';

import '../support/analytics_harness.dart';

void main() {
  testWidgets('every named screen emits screen_viewed and screen_left', (
    tester,
  ) async {
    final client = await installTestAnalytics();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [Analytics.instance.newNavigatorObserver()],
        home: const SizedBox(),
      ),
    );
    client.queue.clear();

    for (final screen in ScreenNames.all) {
      navigator.currentState!.push(
        screenRoute(screen, (_) => const Placeholder()),
      );
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
    }

    final events = screenEvents(client);
    for (final screen in ScreenNames.all) {
      expect(events, contains('screen_viewed:$screen'), reason: screen);
      expect(events, contains('screen_left:$screen'), reason: screen);
    }
    // Each visit is a left with a duration.
    for (final e in queued(client)) {
      if (e['event_name'] == AnalyticsEvent.screenLeft) {
        expect(
          (e['attributes'] as Map)[AnalyticsAttribute.durationMs],
          isA<int>(),
        );
      }
    }
  });

  testWidgets('a named sheet is a screen; an unnamed dialog is not', (
    tester,
  ) async {
    final client = await installTestAnalytics();
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [Analytics.instance.newNavigatorObserver()],
        onGenerateRoute: (_) => screenRoute(ScreenNames.meetupDetail, (c) {
          context = c;
          return const Scaffold();
        }),
      ),
    );
    client.queue.clear();

    showModalBottomSheet<void>(
      context: context,
      routeSettings: const RouteSettings(name: ScreenNames.joinConfirmation),
      builder: (_) => const SizedBox(height: 100),
    );
    await tester.pumpAndSettle();
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    showDialog<void>(context: context, builder: (_) => const SizedBox());
    await tester.pumpAndSettle();

    expect(screenEvents(client), [
      'screen_left:${ScreenNames.meetupDetail}',
      'screen_viewed:${ScreenNames.joinConfirmation}',
      'screen_left:${ScreenNames.joinConfirmation}',
      'screen_viewed:${ScreenNames.meetupDetail}',
    ]);
    expect(Analytics.instance.currentScreen, ScreenNames.meetupDetail);
  });

  test('the shell reports its tab, and only the tab', () {
    final events = <String>[];
    final tracker = ScreenTracker((e, s, _) => events.add('$e:$s'));
    final shell = MaterialPageRoute<void>(
      settings: const RouteSettings(name: ScreenNames.appShell),
      builder: (_) => const SizedBox(),
    );
    tracker.didPush(shell, null);
    tracker.tabChanged(1);
    tracker.tabChanged(1);
    tracker.tabChanged(3);
    expect(events, [
      'screen_viewed:home',
      'screen_left:home',
      'screen_viewed:events',
      'screen_left:events',
      'screen_viewed:profile',
    ]);
    expect(events.where((e) => e.contains(ScreenNames.appShell)), isEmpty);
  });

  test('time in the background is not time on screen', () {
    fakeAsync((async) {
      final left = <int?>[];
      final tracker = ScreenTracker((e, s, ms) {
        if (e == AnalyticsEvent.screenLeft) left.add(ms);
      });
      Route<void> route(String name) => MaterialPageRoute<void>(
        settings: RouteSettings(name: name),
        builder: (_) => const SizedBox(),
      );
      final credits = route(ScreenNames.credits);
      tracker.didPush(credits, null);
      async.elapse(const Duration(seconds: 5));
      tracker.pause();
      async.elapse(const Duration(hours: 1));
      tracker.resume();
      async.elapse(const Duration(seconds: 2));
      tracker.didPush(route(ScreenNames.buyCredits), credits);
      expect(left, [7000]);
    });
  });

  test(
    'a new navigator (the theme switch remounting the app) starts clean',
    () {
      final events = <String>[];
      final tracker = ScreenTracker((e, s, _) => events.add('$e:$s'));
      Route<void> route(String name) => MaterialPageRoute<void>(
        settings: RouteSettings(name: name),
        builder: (_) => const SizedBox(),
      );
      final home = route(ScreenNames.appShell);
      tracker.didPush(home, null);
      tracker.didPush(route(ScreenNames.profile), home);
      // The new navigator's first route: '/', the splash.
      tracker.didPush(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: '/'),
          builder: (_) => const SizedBox(),
        ),
        null,
      );
      expect(events.last, 'screen_viewed:${ScreenNames.splash}');
    },
  );

  // The catalogue is only as good as its coverage: a page pushed without a
  // name is invisible to the tracker, so this fails if one is added.
  test('every route the app pushes is named', () {
    final unnamed = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      if (file.path.endsWith('screen_names.dart')) continue;
      final source = file.readAsStringSync();
      for (final m in RegExp(
        r'MaterialPageRoute(<[^>]*>)?\(',
      ).allMatches(source)) {
        final after = source.substring(m.end).trimLeft();
        if (!after.startsWith('settings:')) {
          final line = '\n'.allMatches(source.substring(0, m.start)).length + 1;
          unnamed.add('${file.path}:$line');
        }
      }
    }
    expect(unnamed, isEmpty, reason: 'name these routes with ScreenNames');
  });
}
