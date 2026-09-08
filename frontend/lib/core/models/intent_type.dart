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

  // Hosting and joining no longer share one bar (ADR-002 § 4, canonical
  // decision ADR-033 § 5). Hosting carries more responsibility — you own a
  // real-world gathering and decide who turns up — so it now needs Level 3,
  // where joining still needs Level 2.
  //
  // Mirrored server-side in the monolith's
  // backend/internal/modules/meetup/trustgate.go
  // (requiredTrustLevelToJoin / requiredTrustLevelToHost). A change to one
  // side must be made on the other, in the same commit — the standing rule
  // from ADR-013 § 2, unchanged.
  //
  // These are ADVISORY here: the server re-checks both on every CreateMeetup
  // and RequestToJoin regardless of what this file says. They exist so the UI
  // can explain a lock before the user hits it, never as the gate itself.

  /// Trust level needed to REQUEST TO JOIN a meetup of this intent.
  /// Unchanged by ADR-002.
  int get requiredTrustLevelToJoin => switch (this) {
    IntentType.rideShare || IntentType.dating => 4,
    _ => 2,
  };

  /// Trust level needed to HOST a meetup of this intent. Raised to 3 for the
  /// four ordinary intents by ADR-002 § 4; ride-share/dating stay at 4 (still
  /// deferred, ADR-004).
  int get requiredTrustLevelToHost => switch (this) {
    IntentType.rideShare || IntentType.dating => 4,
    _ => 3,
  };

  /// Whether [trustLevel] can request to join this intent.
  ///
  /// Deliberately named for the action rather than left as a bare
  /// `isUnlockedFor`: after ADR-002 there is no single "unlocked" state for
  /// an intent, and a call site that does not say which action it means is a
  /// call site that is probably wrong.
  bool canJoin(int trustLevel) => trustLevel >= requiredTrustLevelToJoin;

  /// Whether [trustLevel] can host this intent.
  bool canHost(int trustLevel) => trustLevel >= requiredTrustLevelToHost;

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
