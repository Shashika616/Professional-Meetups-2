import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:professional_connections_platform/core/config/update_required.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/app_config_service.dart';
import 'package:professional_connections_platform/core/services/credit_service.dart';
import 'package:professional_connections_platform/core/services/http_credit_service.dart';
import 'package:professional_connections_platform/core/widgets/update_gate.dart';

class _Config implements AppConfigService {
  _Config(this.minimum);

  String minimum;
  int fetches = 0;

  @override
  Future<RemoteAppConfig> fetch() async {
    fetches++;
    return RemoteAppConfig(minSupportedAppVersion: minimum);
  }
}

Widget _app(_Config config) => ProviderScope(
  overrides: [appConfigServiceProvider.overrideWithValue(config)],
  child: const MaterialApp(home: UpdateGate(child: Text('The app'))),
);

void main() {
  tearDown(() => UpdateRequired.signalled.value = false);

  group('isBelowMinimumVersion', () {
    for (final (minimum, current, below) in [
      ('', '1.1.0+7', false),
      ('nonsense', '1.1.0+7', false),
      ('1.1.0', '1.1.0+7', false),
      ('1.0.9', '1.1.0+7', false),
      ('1.2', '1.1.0+7', true),
      ('1.1.1', '1.1.0+7', true),
      ('2.0.0', '1.9.9+99', true),
      ('1.1.0+8', '1.1.0+7', true),
      ('1.1.0+7', '1.1.0+7', false),
      ('1.10.0', '1.9.0', true),
    ]) {
      test('$minimum against $current', () {
        expect(isBelowMinimumVersion(minimum, current: current), below);
      });
    }
  });

  testWidgets('a supported build sees the app', (tester) async {
    await tester.pumpWidget(_app(_Config('1.0.0')));
    await tester.pumpAndSettle();
    expect(find.text('The app'), findsOneWidget);
    expect(find.byType(UpdateRequiredPage), findsNothing);
  });

  testWidgets('a build below the minimum sees only the update screen', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_Config('99.0.0')));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateRequiredPage), findsOneWidget);
    expect(find.text('The app'), findsNothing);
  });

  testWidgets('no answer from the server blocks nobody', (tester) async {
    await tester.pumpWidget(_app(_Config('')));
    await tester.pumpAndSettle();
    expect(find.text('The app'), findsOneWidget);
  });

  testWidgets('the minimum is read again on return to the foreground', (
    tester,
  ) async {
    final config = _Config('1.0.0');
    await tester.pumpWidget(_app(config));
    await tester.pumpAndSettle();
    expect(find.text('The app'), findsOneWidget);

    config.minimum = '99.0.0';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(config.fetches, greaterThanOrEqualTo(2));
    expect(find.byType(UpdateRequiredPage), findsOneWidget);
  });

  testWidgets('the Update button opens the store', (tester) async {
    Uri? opened;
    await tester.pumpWidget(
      MaterialApp(home: UpdateRequiredPage(open: (uri) async => opened = uri)),
    );
    await tester.tap(find.text('Update'));
    await tester.pump();
    expect(opened?.host, 'play.google.com');
  });

  testWidgets('a 426 from the credit client brings up the same screen', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_Config('')));
    await tester.pumpAndSettle();
    final credits = HttpCreditService(
      httpClient: MockClient(
        (_) async => http.Response('{"error":"update_required"}', 426),
      ),
      baseUrl: 'http://localhost:8080',
      getAccessToken: () async => 'tok',
    );
    await expectLater(
      credits.wallet,
      throwsA(isA<CreditUpdateRequiredException>()),
    );
    await tester.pumpAndSettle();
    expect(find.byType(UpdateRequiredPage), findsOneWidget);
  });

  group('forced update', () {
    Map<String, dynamic> config({bool on = true, String min = '99.0.0'}) => {
      'flags': {'app.force_update': on},
      'values': {
        'app.force_update': {
          'min_version': {'android': min, 'ios': min},
          'message': 'A security fix needs this update.',
          'store_url': {'android': 'https://example.com/play'},
        },
      },
    };

    Widget app(RemoteAppConfig remote) => ProviderScope(
      overrides: [appConfigProvider.overrideWith((ref) async => remote)],
      child: const MaterialApp(home: UpdateGate(child: Text('The app'))),
    );

    testWidgets('shows the operator\'s message and blocks the app', (
      tester,
    ) async {
      await tester.pumpWidget(app(RemoteAppConfig.fromJson(config())));
      await tester.pumpAndSettle();
      expect(find.text('A security fix needs this update.'), findsOneWidget);
      expect(find.text('The app'), findsNothing);
    });

    testWidgets('does nothing while the flag is off', (tester) async {
      await tester.pumpWidget(app(RemoteAppConfig.fromJson(config(on: false))));
      await tester.pumpAndSettle();
      expect(find.text('The app'), findsOneWidget);
    });

    testWidgets('a current build is not blocked', (tester) async {
      await tester.pumpWidget(
        app(RemoteAppConfig.fromJson(config(min: '1.0.0'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('The app'), findsOneWidget);
    });

    testWidgets('Update opens the store page the operator set', (tester) async {
      Uri? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: UpdateRequiredPage(
            storeUrl: 'https://example.com/play',
            open: (uri) async => opened = uri,
          ),
        ),
      );
      await tester.tap(find.text('Update'));
      await tester.pump();
      expect(opened.toString(), 'https://example.com/play');
    });

    testWidgets('anything but https falls back to the built-in store page', (
      tester,
    ) async {
      Uri? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: UpdateRequiredPage(
            storeUrl: 'tel:+94770000000',
            open: (uri) async => opened = uri,
          ),
        ),
      );
      await tester.tap(find.text('Update'));
      await tester.pump();
      expect(opened?.scheme, 'https');
    });

    test('a malformed value forces nobody', () {
      final remote = RemoteAppConfig.fromJson({
        'flags': {'app.force_update': true},
        'values': {'app.force_update': 3},
      });
      expect(remote.forceUpdate.enabled, isFalse);
    });
  });
}
