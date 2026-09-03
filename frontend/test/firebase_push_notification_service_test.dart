import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/services/firebase_push_notification_service.dart';

/// Only the pure `pushMessageFromRemoteMessage` mapping is unit-tested
/// here (ADR-030, round-10 Step 5/Tests) — constructing a [RemoteMessage]
/// directly needs no platform channel, so this is genuinely exercised, not
/// faked. `FirebasePushNotificationService` itself (`initialize()`,
/// `currentToken()`, real message delivery) is NOT meaningfully
/// unit-testable under `flutter test` without a real Firebase platform
/// channel — this codebase already accepts that same limitation for
/// `geolocator`/`flutter_secure_storage` (faked platform interfaces for
/// what's fakeable, honest disclosure for what isn't; Firebase has no
/// equivalent fake-platform-interface package in this project), so no
/// test here claims to exercise the real plugin.
void main() {
  group('pushMessageFromRemoteMessage (ADR-030, round-10)', () {
    test('maps data type/meetup_id and notification title/body', () {
      final message = RemoteMessage(
        data: const {'type': 'meetup_closed', 'meetup_id': 'meetup-42'},
        notification: const RemoteNotification(
          title: 'Meetup closed',
          body: 'Your coffee meetup has ended.',
        ),
      );

      final result = pushMessageFromRemoteMessage(message);

      expect(result.type, 'meetup_closed');
      expect(result.meetupId, 'meetup-42');
      expect(result.title, 'Meetup closed');
      expect(result.body, 'Your coffee meetup has ended.');
    });

    test('a data-only message (no notification block) falls back to empty '
        'title/body, not null — matches PushMessage\'s own non-nullable '
        'fields', () {
      final message = RemoteMessage(
        data: const {'type': 'meetup_closed', 'meetup_id': 'meetup-7'},
      );

      final result = pushMessageFromRemoteMessage(message);

      expect(result.type, 'meetup_closed');
      expect(result.meetupId, 'meetup-7');
      expect(result.title, '');
      expect(result.body, '');
    });

    test('missing meetup_id maps to a null PushMessage.meetupId', () {
      final message = RemoteMessage(
        data: const {'type': 'some_other_type'},
        notification: const RemoteNotification(
          title: 'Something happened',
          body: 'Details',
        ),
      );

      final result = pushMessageFromRemoteMessage(message);

      expect(result.type, 'some_other_type');
      expect(result.meetupId, isNull);
    });

    test('missing type maps to an empty string, not null', () {
      final message = RemoteMessage(
        data: const {},
        notification: const RemoteNotification(title: 'Title', body: 'Body'),
      );

      final result = pushMessageFromRemoteMessage(message);

      expect(result.type, '');
    });
  });
}
