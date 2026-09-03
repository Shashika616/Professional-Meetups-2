import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/services/push_notification_service.dart';

void main() {
  group('NoOpPushNotificationService (ADR-030, round-9 scaffolding)', () {
    test('currentToken() always returns null', () async {
      final service = NoOpPushNotificationService();
      expect(await service.currentToken(), isNull);
      // Called twice deliberately — not just "returns null once," genuinely
      // never produces a real token.
      expect(await service.currentToken(), isNull);
    });

    test('initialize() completes without throwing', () async {
      final service = NoOpPushNotificationService();
      await expectLater(service.initialize(), completes);
    });

    test('messages never emits any PushMessage', () async {
      final service = NoOpPushNotificationService();
      final received = await service.messages.toList();
      expect(received, isEmpty);
    });
  });
}
