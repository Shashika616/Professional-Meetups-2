import 'package:flutter/foundation.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';

/// What one member may see of another — `GET /v1/users/{id}`.
///
/// Deliberately a different type from `UserProfile`: that one is the
/// owner's own view and carries their phone number, personal email, legal
/// name and address. This one has no field for any of those, so a screen
/// built on it cannot show them by accident. The three verification flags
/// are rendered as badges, never as the value they verify.
@immutable
class PublicProfile {
  const PublicProfile({
    required this.id,
    required this.fullName,
    this.profilePhotoUrl = '',
    required this.trustLevel,
    this.ratingAverage = 0,
    this.ratingCount = 0,
    this.meetupsCompleted = 0,
    this.linkedInConnected = false,
    this.workEmailVerified = false,
    this.phoneVerified = false,
    this.recentMeetups = const [],
    this.reviews = const [],
  });

  factory PublicProfile.fromJson(Map<String, dynamic> json) => PublicProfile(
    id: json['user_id'] as String,
    fullName: json['full_name'] as String? ?? '',
    profilePhotoUrl: json['photo_url'] as String? ?? '',
    trustLevel: (json['trust_level'] as num?)?.toInt() ?? 0,
    ratingAverage: (json['rating_average'] as num?)?.toDouble() ?? 0,
    ratingCount: (json['rating_count'] as num?)?.toInt() ?? 0,
    meetupsCompleted: (json['meetups_completed'] as num?)?.toInt() ?? 0,
    linkedInConnected: json['linkedin_connected'] as bool? ?? false,
    workEmailVerified: json['work_email_verified'] as bool? ?? false,
    phoneVerified: json['phone_verified'] as bool? ?? false,
    recentMeetups: [
      for (final m in (json['recent_meetups'] as List<dynamic>? ?? const []))
        MemberMeetup.fromJson(m as Map<String, dynamic>),
    ],
    reviews: [
      for (final r in (json['reviews'] as List<dynamic>? ?? const []))
        MemberReview.fromJson(r as Map<String, dynamic>),
    ],
  );

  final String id;
  final String fullName;
  final String profilePhotoUrl;
  final int trustLevel;
  final double ratingAverage;
  final int ratingCount;
  final int meetupsCompleted;

  /// LinkedIn identity linked — shown as the "Professional" badge.
  final bool linkedInConnected;

  /// A company-domain email verified — shown as the "Official" badge.
  final bool workEmailVerified;

  /// Phone number verified by OTP — shown as "Phone verified".
  final bool phoneVerified;

  /// The finished meetups this member hosted, newest first. Empty for a
  /// member who only joined: they show a count and a rating, nothing more.
  final List<MemberMeetup> recentMeetups;

  /// What participants wrote about this host, always anonymous.
  final List<MemberReview> reviews;
}

/// One finished meetup a member hosted: what it was, the day, the area, the
/// turnout and the rating. [day] is a date; its time of day means nothing.
@immutable
class MemberMeetup {
  const MemberMeetup({
    required this.intent,
    required this.day,
    required this.locationLabel,
    required this.participantCount,
    required this.overallAverage,
    required this.reviewCount,
  });

  factory MemberMeetup.fromJson(Map<String, dynamic> json) => MemberMeetup(
    intent: IntentType.fromWire(json['intent'] as String? ?? ''),
    day: DateTime.fromMillisecondsSinceEpoch(
      ((json['window_start_unix_seconds'] as num?)?.toInt() ?? 0) * 1000,
    ),
    locationLabel: json['location_label'] as String? ?? '',
    participantCount: (json['participant_count'] as num?)?.toInt() ?? 0,
    overallAverage: (json['overall_average'] as num?)?.toDouble() ?? 0,
    reviewCount: (json['review_count'] as num?)?.toInt() ?? 0,
  );

  final IntentType intent;
  final DateTime day;
  final String locationLabel;
  final int participantCount;
  final double overallAverage;
  final int reviewCount;
}

/// One anonymous review: a score, the text and a month. The server sends
/// nothing that could name the author, for any viewer, and there is no field
/// here to hold it.
@immutable
class MemberReview {
  const MemberReview({
    required this.score,
    required this.text,
    required this.month,
  });

  factory MemberReview.fromJson(Map<String, dynamic> json) => MemberReview(
    score: (json['score'] as num?)?.toInt() ?? 0,
    text: json['text'] as String? ?? '',
    month: json['month'] as String? ?? '',
  );

  final int score;
  final String text;

  /// `YYYY-MM`.
  final String month;
}
