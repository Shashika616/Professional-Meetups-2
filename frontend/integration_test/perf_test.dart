// Frame timings for the screens people use most, in a profile build on a
// real device or emulator. Not a pass/fail test: it records, and the driver
// writes build/<name>.timeline_summary.json with frame build and raster
// percentiles and missed-frame counts.
//
//   flutter drive --profile --driver=test_driver/perf_driver.dart \
//     --target=integration_test/perf_test.dart
//
// Fake services stand in for the backend, so the numbers measure the app,
// not the network.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:integration_test/integration_test.dart';

import 'package:professional_connections_platform/app_shell.dart';
import 'package:professional_connections_platform/core/models/auth_session.dart';
import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/push_notification_service.dart';
import 'package:professional_connections_platform/core/services/subscription_service.dart';
import 'package:professional_connections_platform/features/home/viewer_location_provider.dart';
import 'package:professional_connections_platform/features/meetups/widgets/android_map_location_step.dart';

import '../test/support/fake_auth_service.dart';
import '../test/support/scripted_meetup_service.dart';

class _SignedIn extends AuthSessionNotifier {
  @override
  Future<AuthSessionState> build() async => AuthSessionState(
    session: AuthSession(
      userId: 'user-1',
      accessToken: 'a1',
      refreshToken: 'r1',
      trustLevel: 3,
      isNewUser: false,
      accessTokenExpiresAt: DateTime.now().add(const Duration(hours: 1)),
      fullName: 'Ada Lovelace',
      profilePhotoUrl: '',
    ),
  );
}

/// No real store: the Profile tab would otherwise call the gateway.
class _FreeTier implements SubscriptionService {
  @override
  Future<List<ProductDetails>> availableProducts(List<String> ids) async => [];

  @override
  Future<SubscriptionStatus> currentStatus() async => const SubscriptionStatus(
    tier: SubscriptionTier.free,
    status: SubscriptionLifecycleStatus.none,
  );

  @override
  Future<void> restorePurchases() async {}

  @override
  Future<SubscriptionStatus> verifyPurchase({
    required String platform,
    required String receiptOrToken,
    required String productId,
  }) async => throw UnimplementedError();
}

/// A fixed position, so Home never asks the real location service — whose
/// permission dialog would sit over the screen being measured.
Future<Position> _colombo() async => Position(
  latitude: 6.9271,
  longitude: 79.8612,
  timestamp: DateTime.now(),
  accuracy: 10,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

List<Meetup> _meetups(int n) {
  final now = DateTime.now();
  const intents = [
    IntentType.coffee,
    IntentType.lunch,
    IntentType.networking,
    IntentType.mentorship,
  ];
  return List.generate(n, (i) {
    final start = now.add(Duration(hours: 3 + i * 5));
    return Meetup(
      id: 'm$i',
      hostUserId: 'host-$i',
      hostFullName: 'Host Number $i',
      hostTrustLevel: 2 + i % 3,
      intent: intents[i % intents.length],
      windowStart: start,
      windowEnd: start.add(const Duration(hours: 2)),
      locationLat: 6.9271 + i * 0.001,
      locationLng: 79.8612 + i * 0.001,
      locationLabel: 'Seeded Cafe $i, Colombo',
      capacity: 4,
      acceptedCount: i % 4,
      status: MeetupStatus.open,
      createdAt: now.subtract(Duration(hours: i)),
    );
  });
}

Future<void> _settleFor(WidgetTester tester, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The control: the cheapest scrolling screen Flutter can draw, flung the
  // same way as Home. Whatever this costs is the device's floor, not the
  // app's; the other scenarios are judged against it.
  testWidgets('control: a plain list', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            itemCount: 200,
            itemBuilder: (_, i) => ListTile(title: Text('Row $i')),
          ),
        ),
      ),
    );
    await _settleFor(tester, const Duration(seconds: 1));
    await binding.traceAction(() async {
      final scrollable = find.byType(Scrollable).first;
      for (var i = 0; i < 4; i++) {
        await tester.fling(scrollable, const Offset(0, -900), 2500);
        await _settleFor(tester, const Duration(milliseconds: 900));
      }
      for (var i = 0; i < 4; i++) {
        await tester.fling(scrollable, const Offset(0, 900), 2500);
        await _settleFor(tester, const Duration(milliseconds: 900));
      }
    }, reportKey: 'control_plain_list');
  });

  testWidgets('home, tabs and scrolling', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authSessionProvider.overrideWith(_SignedIn.new),
          authServiceProvider.overrideWithValue(ImmediateAuthService()),
          meetupServiceProvider.overrideWithValue(
            ScriptedMeetupService(openMeetups: _meetups(30)),
          ),
          pushNotificationServiceProvider.overrideWithValue(
            NoOpPushNotificationService(),
          ),
          subscriptionServiceProvider.overrideWithValue(_FreeTier()),
          viewerLocationSourceProvider.overrideWithValue(_colombo),
        ],
        child: const MaterialApp(home: AppShell()),
      ),
    );
    await _settleFor(tester, const Duration(seconds: 3));

    await binding.traceAction(() async {
      final scrollable = find.byType(Scrollable).first;
      for (var i = 0; i < 4; i++) {
        await tester.fling(scrollable, const Offset(0, -900), 2500);
        await _settleFor(tester, const Duration(milliseconds: 900));
      }
      for (var i = 0; i < 4; i++) {
        await tester.fling(scrollable, const Offset(0, 900), 2500);
        await _settleFor(tester, const Duration(milliseconds: 900));
      }
    }, reportKey: 'home_scroll');

    // Twice round: the first visit builds each tab, the second is a switch.
    for (final tab in ['Events', 'Safety', 'Profile', 'Home']) {
      await binding.traceAction(() async {
        await tester.tap(find.text(tab).last);
        await _settleFor(tester, const Duration(milliseconds: 1200));
      }, reportKey: 'first_visit_${tab.toLowerCase()}');
    }

    await binding.traceAction(() async {
      for (final tab in ['Events', 'Safety', 'Profile', 'Home']) {
        await tester.tap(find.text(tab).last);
        await _settleFor(tester, const Duration(milliseconds: 1200));
      }
    }, reportKey: 'tabs_revisit');
  });

  testWidgets('location picker with the keyboard', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          resizeToAvoidBottomInset: false,
          body: SizedBox.expand(
            child: AndroidMapLocationStep(onSubmit: (_, _, _) {}),
          ),
        ),
      ),
    );
    await _settleFor(tester, const Duration(seconds: 4));

    await binding.traceAction(() async {
      final field = find.byType(TextField).first;
      for (var i = 0; i < 2; i++) {
        await tester.tap(field); // the real keyboard slides up
        await _settleFor(tester, const Duration(milliseconds: 900));
        await tester.enterText(field, 'cof');
        await _settleFor(tester, const Duration(milliseconds: 1500));
        FocusManager.instance.primaryFocus?.unfocus(); // and down
        await _settleFor(tester, const Duration(milliseconds: 900));
        await tester.enterText(field, '');
        await _settleFor(tester, const Duration(milliseconds: 300));
      }
    }, reportKey: 'location_picker_keyboard');
  });
}
