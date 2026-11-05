import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/features/home/widgets/home_header.dart';
import 'package:professional_connections_platform/features/notifications/notifications_page.dart';

import 'support/scripted_meetup_service.dart';

class _SignedIn extends AuthSessionNotifier {
  @override
  Future<AuthSessionState> build() async => const AuthSessionState(
    profile: UserProfile(id: 'user-1', fullName: 'Ada', trustLevel: 2),
  );
}

AppNotification _note(String id, DateTime at) =>
    AppNotification(id: id, title: 'Title $id', body: 'Body', createdAt: at);

void main() {
  const dot = Key('notification-dot');

  testWidgets('the bell has a dot only when told there is something new', (
    tester,
  ) async {
    Widget header(bool isNew) => MaterialApp(
      home: Scaffold(
        body: HomeHeader(userName: 'Ada', hasNewNotifications: isNew),
      ),
    );
    await tester.pumpWidget(header(false));
    expect(find.byKey(dot), findsNothing);
    await tester.pumpWidget(header(true));
    await tester.pump();
    expect(find.byKey(dot), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  group('what counts as new', () {
    final at = DateTime(2026, 11, 4, 12);

    ProviderContainer container(ScriptedMeetupService service) {
      final c = ProviderContainer(
        overrides: [
          authSessionProvider.overrideWith(_SignedIn.new),
          meetupServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('nothing sent is nothing new', () async {
      final c = container(ScriptedMeetupService());
      await c.read(authSessionProvider.future);
      expect(await c.read(hasNewNotificationsProvider.future), isFalse);
    });

    test(
      'a notification never opened is new, and an older one is not',
      () async {
        final service = ScriptedMeetupService()
          ..notifications = [_note('1', at)];
        final c = container(service);
        await c.read(authSessionProvider.future);
        expect(await c.read(hasNewNotificationsProvider.future), isTrue);

        SharedPreferences.setMockInitialValues({
          'notifications_seen_at.user-1': at.millisecondsSinceEpoch,
        });
        c.invalidate(hasNewNotificationsProvider);
        expect(await c.read(hasNewNotificationsProvider.future), isFalse);
      },
    );

    test('a failed read shows no dot', () async {
      final service = ScriptedMeetupService()
        ..notificationsError = StateError('offline');
      final c = container(service);
      await c.read(authSessionProvider.future);
      expect(await c.read(hasNewNotificationsProvider.future), isFalse);
    });
  });

  testWidgets('opening Notifications clears the dot', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final at = DateTime(2026, 11, 4, 12);
    final service = ScriptedMeetupService()..notifications = [_note('1', at)];
    final c = ProviderContainer(
      overrides: [
        authSessionProvider.overrideWith(_SignedIn.new),
        meetupServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(c.dispose);
    await c.read(authSessionProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: NotificationsPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getInt('notifications_seen_at.user-1'),
      at.millisecondsSinceEpoch,
    );
  });
}
