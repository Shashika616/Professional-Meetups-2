import 'package:flutter_test/flutter_test.dart';
import 'package:professional_connections_platform/core/models/intent_type.dart';

void main() {
  // SPLIT, not extended (ADR-002 § 4). The single `requiredTrustLevel` group
  // this file used to have could not simply gain cases: hosting and joining
  // no longer share a number, so one table asserting one value per intent
  // would have to be wrong about one of the two actions.
  //
  // These values are MIRRORED in the backend's
  // backend/internal/modules/meetup/trustgate.go. A change to one side must
  // be made on the other, in the same commit (ADR-013 § 2's standing rule).
  group('IntentType.requiredTrustLevelToJoin (ADR-002 § 4)', () {
    test('ordinary intents need Level 2 — UNCHANGED by ADR-002', () {
      expect(IntentType.coffee.requiredTrustLevelToJoin, 2);
      expect(IntentType.lunch.requiredTrustLevelToJoin, 2);
      expect(IntentType.networking.requiredTrustLevelToJoin, 2);
      expect(IntentType.mentorship.requiredTrustLevelToJoin, 2);
    });

    test('deferred intents need Level 4', () {
      expect(IntentType.rideShare.requiredTrustLevelToJoin, 4);
      expect(IntentType.dating.requiredTrustLevelToJoin, 4);
    });

    test('canJoin gates strictly on the join level', () {
      expect(IntentType.coffee.canJoin(1), isFalse);
      expect(IntentType.coffee.canJoin(2), isTrue);
      expect(IntentType.rideShare.canJoin(3), isFalse);
      expect(IntentType.rideShare.canJoin(4), isTrue);
    });
  });

  group('IntentType.requiredTrustLevelToHost (ADR-002 § 4)', () {
    test('ordinary intents need Level 3 — RAISED from 2', () {
      expect(IntentType.coffee.requiredTrustLevelToHost, 3);
      expect(IntentType.lunch.requiredTrustLevelToHost, 3);
      expect(IntentType.networking.requiredTrustLevelToHost, 3);
      expect(IntentType.mentorship.requiredTrustLevelToHost, 3);
    });

    test('deferred intents stay at Level 4 for both actions (ADR-004)', () {
      expect(IntentType.rideShare.requiredTrustLevelToHost, 4);
      expect(IntentType.dating.requiredTrustLevelToHost, 4);
    });

    test('canHost gates strictly on the host level', () {
      expect(IntentType.coffee.canHost(2), isFalse);
      expect(IntentType.coffee.canHost(3), isTrue);
      expect(IntentType.rideShare.canHost(3), isFalse);
      expect(IntentType.rideShare.canHost(4), isTrue);
    });
  });

  group('the host/join relationship', () {
    // The behaviour change, stated as its own assertion rather than left to
    // be inferred from two separate tables: a Level 2 user can join an
    // ordinary meetup but can no longer host one.
    test('Level 2 can join but not host an ordinary meetup', () {
      for (final intent in [
        IntentType.coffee,
        IntentType.lunch,
        IntentType.networking,
        IntentType.mentorship,
      ]) {
        expect(intent.canJoin(2), isTrue, reason: '${intent.label} at L2');
        expect(intent.canHost(2), isFalse, reason: '${intent.label} at L2');
      }
    });

    // Mirrors the backend's TestHostBarIsNeverBelowJoinBar. If hosting were
    // ever easier than joining, someone could create a meetup they could not
    // themselves join.
    test('the host bar is never below the join bar', () {
      for (final intent in IntentType.values) {
        expect(
          intent.requiredTrustLevelToHost,
          greaterThanOrEqualTo(intent.requiredTrustLevelToJoin),
          reason: '${intent.label}: host bar is below the join bar',
        );
      }
    });
  });
}
