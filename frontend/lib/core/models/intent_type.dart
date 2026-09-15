import 'package:flutter/material.dart';

enum IntentType {
  coffee,
  lunch,
  networking,
  mentorship,
  outing,
  rideShare,
  dating;

  /// The intent's name, without any time-of-day qualifier. For
  /// [IntentType.lunch] that is MEAL; where a start time is known, use
  /// [labelFor] so the sitting (breakfast, dinner...) is named as well.
  String get label => switch (this) {
    IntentType.coffee => 'COFFEE',
    IntentType.lunch => 'MEAL',
    IntentType.networking => 'NETWORKING',
    IntentType.mentorship => 'MENTORSHIP',
    // Not 'EVENTS': the bottom tab already carries that word, and the
    // Home filter chips render every label on the same screen as it.
    IntentType.outing => 'OUTING',
    IntentType.rideShare => 'RIDE SHARE',
    IntentType.dating => 'DATING',
  };

  /// One line of intent, shown under the name on the Schedule flow's
  /// picker cards. Short enough to sit on a half-width card at 11px.
  String get tagline => switch (this) {
    IntentType.coffee => 'A quick cup, a new connection',
    IntentType.lunch => 'Breakfast, lunch or dinner: the time decides',
    IntentType.networking => 'Grow your circle',
    IntentType.mentorship => 'Learn from someone a step ahead',
    IntentType.outing => 'A gig, a game, a night out',
    IntentType.rideShare => 'Share the road, split the fare',
    IntentType.dating => 'Connect beyond the office',
  };

  /// The label with the sitting named from [windowStart], in the device's
  /// local time: "MEAL: BREAKFAST", "MEAL: DINNER". Only the meal intent
  /// changes; every other intent is its plain [label]. One intent covers
  /// every meal (2026-09-15) so the host picks a time, not a meal, and the
  /// name follows. Null [windowStart] (a locked meetup hides its window)
  /// gives the plain label.
  String labelFor(DateTime? windowStart) {
    if (this != IntentType.lunch || windowStart == null) return label;
    return '$label: ${MealSitting.at(windowStart).label}';
  }

  /// The landing-collage scene that best reads as this intent, reused as
  /// the picker card's backdrop so the flow shares the landing page's
  /// visual language instead of introducing new artwork. Chosen by eye
  /// from the 29 scenes: two colleagues over cups for coffee, a table
  /// being toasted for lunch, a rooftop mixer for networking, a whiteboard
  /// session for mentorship, a concert crowd for outing, a candlelit table
  /// for dating. There is no
  /// vehicle scene at all, so ride share gets a window onto the street and
  /// lets its icon do the talking.
  String get imageAsset => switch (this) {
    IntentType.coffee => 'assets/images/landing/l13.jpg',
    IntentType.lunch => 'assets/images/landing/l11.jpg',
    IntentType.networking => 'assets/images/landing/l14.jpg',
    IntentType.mentorship => 'assets/images/landing/l10.jpg',
    IntentType.outing => 'assets/images/landing/l05.jpg',
    IntentType.rideShare => 'assets/images/landing/l15.jpg',
    IntentType.dating => 'assets/images/landing/l28.jpg',
  };

  IconData get icon => switch (this) {
    IntentType.coffee => Icons.local_cafe_outlined,
    IntentType.lunch => Icons.restaurant_outlined,
    IntentType.networking => Icons.work_outline,
    IntentType.mentorship => Icons.school_outlined,
    IntentType.outing => Icons.celebration_outlined,
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

  /// The intent's name in a sentence: "coffee", "meal", "ride share".
  String get sentenceName => label.toLowerCase();

  /// The one line shown (as a toast, on the way to the verification
  /// checklist) when the viewer is below the join bar. It says what to do
  /// and why, and nothing else: the checklist page it accompanies is where
  /// the specific steps and levels live, so repeating "Level 2 trust" and
  /// the list of verifications here only made the toast long and
  /// technical. Same shape for every intent, so the app speaks with one
  /// voice.
  String get joinLockedMessage =>
      'Verify your account to join $sentenceName meetups.';

  /// The hosting counterpart of [joinLockedMessage], shown on the way to
  /// the hosting unlock page.
  String get hostLockedMessage =>
      'Verify your account to host $sentenceName meetups.';

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

  /// The trust ladder today is 0–3 (ADR-033 § 5). A required level above
  /// it is the sentinel for an intent that is deferred rather than gated
  /// (ADR-004: ride share and dating) — no evidence a user can add reaches
  /// it. UI that names the level to unlock must not print that sentinel as
  /// if it were a real rung.
  static const int highestTrustLevel = 3;

  /// True when hosting this intent is deferred outright (ADR-004), as
  /// opposed to locked behind a level the user could still earn.
  bool get hostingDeferred => requiredTrustLevelToHost > highestTrustLevel;

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
    IntentType.outing => 'outing',
    IntentType.rideShare => 'ride_share',
    IntentType.dating => 'dating',
  };

  static IntentType fromWire(String value) => switch (value) {
    'coffee' => IntentType.coffee,
    'lunch' => IntentType.lunch,
    'networking' => IntentType.networking,
    'mentorship' => IntentType.mentorship,
    'outing' => IntentType.outing,
    'ride_share' => IntentType.rideShare,
    'dating' => IntentType.dating,
    _ => throw FormatException('Unknown intent: $value'),
  };
}

/// Which meal a [IntentType.lunch] meetup is, decided by its local start
/// hour. The bands are the product's (2026-09-15): breakfast 04:00–10:59,
/// lunch 11:00–13:59, an evening meal 14:00–17:59, dinner 18:00–21:59, and
/// a late-night meal from 22:00 to 03:59. Half-open, so 11:00 is lunch and
/// 18:00 is dinner.
enum MealSitting {
  breakfast('BREAKFAST'),
  lunch('LUNCH'),
  eveningMeal('EVENING MEAL'),
  dinner('DINNER'),
  lateNight('LATE NIGHT MEAL');

  const MealSitting(this.label);

  final String label;

  static MealSitting at(DateTime start) {
    final hour = start.hour;
    if (hour >= 4 && hour < 11) return MealSitting.breakfast;
    if (hour >= 11 && hour < 14) return MealSitting.lunch;
    if (hour >= 14 && hour < 18) return MealSitting.eveningMeal;
    if (hour >= 18 && hour < 22) return MealSitting.dinner;
    return MealSitting.lateNight;
  }
}
