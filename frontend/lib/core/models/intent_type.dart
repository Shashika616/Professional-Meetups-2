import 'package:flutter/material.dart';

enum IntentType {
  coffee,
  lunch,
  networking,
  mentorship,
  rideShare,
  dating;

  String get label => switch (this) {
    IntentType.coffee => 'COFFEE',
    IntentType.lunch => 'LUNCH',
    IntentType.networking => 'NETWORKING',
    IntentType.mentorship => 'MENTORSHIP',
    IntentType.rideShare => 'RIDE SHARE',
    IntentType.dating => 'DATING',
  };

  IconData get icon => switch (this) {
    IntentType.coffee => Icons.local_cafe_outlined,
    IntentType.lunch => Icons.restaurant_outlined,
    IntentType.networking => Icons.work_outline,
    IntentType.mentorship => Icons.school_outlined,
    IntentType.rideShare => Icons.directions_car_outlined,
    IntentType.dating => Icons.favorite_border,
  };

  // Level 2, not Level 1 — hosting/joining a real-world meetup with a
  // stranger is "the real floor for matching and messaging with strangers"
  // (ADR-006), which ADR-013 § 2 applies here: Level 1 (federated LinkedIn
  // only) still unlocks browsing/viewing open meetups, but not hosting or
  // requesting to join one. Mirrored server-side in
  // services/meetup/internal/service/trustgate.go — a change to one side
  // must be made on the other too.
  int get requiredTrustLevel => switch (this) {
    IntentType.rideShare || IntentType.dating => 4,
    _ => 2,
  };

  bool isUnlockedFor(int trustLevel) => trustLevel >= requiredTrustLevel;

  /// Wire format for the meetup-scheduling REST API — matches the
  /// backend's intent_type Postgres enum values exactly (snake_case;
  /// `.name` alone would serialize rideShare as "rideShare", not the
  /// backend's "ride_share"). Three-way duplication with the backend enum
  /// and its own proto enum, noted explicitly on all three sides
  /// (ADR-013, backend/meetup-scheduling-PLAN.md Step A).
  String get wireValue => switch (this) {
    IntentType.coffee => 'coffee',
    IntentType.lunch => 'lunch',
    IntentType.networking => 'networking',
    IntentType.mentorship => 'mentorship',
    IntentType.rideShare => 'ride_share',
    IntentType.dating => 'dating',
  };

  static IntentType fromWire(String value) => switch (value) {
    'coffee' => IntentType.coffee,
    'lunch' => IntentType.lunch,
    'networking' => IntentType.networking,
    'mentorship' => IntentType.mentorship,
    'ride_share' => IntentType.rideShare,
    'dating' => IntentType.dating,
    _ => throw FormatException('Unknown intent: $value'),
  };
}
