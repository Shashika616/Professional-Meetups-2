import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';

void main() {
  group('IntentType.requiredTrustLevel (ADR-013 § 2)', () {
    test('coffee/lunch/networking/mentorship require Level 2, not 1', () {
      expect(IntentType.coffee.requiredTrustLevel, 2);
      expect(IntentType.lunch.requiredTrustLevel, 2);
      expect(IntentType.networking.requiredTrustLevel, 2);
      expect(IntentType.mentorship.requiredTrustLevel, 2);
    });

    test('rideShare/dating stay at Level 4 (ADR-004 deferral)', () {
      expect(IntentType.rideShare.requiredTrustLevel, 4);
      expect(IntentType.dating.requiredTrustLevel, 4);
    });

    test('isUnlockedFor gates strictly on the required level', () {
      expect(IntentType.coffee.isUnlockedFor(1), isFalse);
      expect(IntentType.coffee.isUnlockedFor(2), isTrue);
      expect(IntentType.rideShare.isUnlockedFor(3), isFalse);
      expect(IntentType.rideShare.isUnlockedFor(4), isTrue);
    });
  });

  group('IntentType wire format', () {
    test('wireValue is snake_case, matching the backend enum', () {
      expect(IntentType.coffee.wireValue, 'coffee');
      expect(IntentType.rideShare.wireValue, 'ride_share');
    });

    test('fromWire round-trips every value through wireValue', () {
      for (final intent in IntentType.values) {
        expect(IntentType.fromWire(intent.wireValue), intent);
      }
    });

    test('fromWire throws FormatException on an unknown value', () {
      expect(() => IntentType.fromWire('bogus'), throwsFormatException);
    });
  });
}
