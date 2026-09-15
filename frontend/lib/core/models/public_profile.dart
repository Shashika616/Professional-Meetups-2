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
  });

  factory PublicProfile.fromJson(Map<String, dynamic> json) => PublicProfile(
    id: json['user_id'] as String,
    fullName: json['full_name'] as String? ?? '',
    profilePhotoUrl: json['profile_photo_url'] as String? ?? '',
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

  /// The member's last few meetups as host or participant, newest first.
  final List<MemberMeetup> recentMeetups;
}

/// One meetup on a member's profile. Comment authors are named only when
/// the VIEWER was on that meetup ([viewerWasIn]); the server sends an
/// empty [MemberMeetupComment.authorName] otherwise, and the UI must not
/// try to fill it in from anywhere else.
@immutable
class MemberMeetup {
  const MemberMeetup({
    required this.id,
    required this.intent,
    required this.status,
    required this.windowStart,
    required this.windowEnd,
    required this.locationLabel,
    required this.hosted,
    required this.participantCount,
    required this.overallAverage,
    required this.reviewCount,
    required this.viewerWasIn,
    this.comments = const [],
  });

  factory MemberMeetup.fromJson(Map<String, dynamic> json) => MemberMeetup(
    id: json['id'] as String,
    intent: IntentType.fromWire(json['intent'] as String? ?? ''),
    status: json['status'] as String? ?? '',
    windowStart: DateTime.fromMillisecondsSinceEpoch(
      ((json['window_start_unix_seconds'] as num?)?.toInt() ?? 0) * 1000,
    ),
    windowEnd: DateTime.fromMillisecondsSinceEpoch(
      ((json['window_end_unix_seconds'] as num?)?.toInt() ?? 0) * 1000,
    ),
    locationLabel: json['location_label'] as String? ?? '',
    hosted: json['hosted'] as bool? ?? false,
    participantCount: (json['participant_count'] as num?)?.toInt() ?? 0,
    overallAverage: (json['overall_average'] as num?)?.toDouble() ?? 0,
    reviewCount: (json['review_count'] as num?)?.toInt() ?? 0,
    viewerWasIn: json['viewer_was_in'] as bool? ?? false,
    comments: [
      for (final c in (json['comments'] as List<dynamic>? ?? const []))
        MemberMeetupComment.fromJson(c as Map<String, dynamic>),
    ],
  );

  final String id;
  final IntentType intent;
  final String status;
  final DateTime windowStart;
  final DateTime windowEnd;
  final String locationLabel;
  final bool hosted;
  final int participantCount;
  final double overallAverage;
  final int reviewCount;
  final bool viewerWasIn;
  final List<MemberMeetupComment> comments;

  /// See [Meetup.intentLabel]: the meal intent names its sitting.
  String get intentLabel => intent.labelFor(windowStart);
}

@immutable
class MemberMeetupComment {
  const MemberMeetupComment({
    required this.authorName,
    required this.note,
    required this.writtenAt,
  });

  factory MemberMeetupComment.fromJson(Map<String, dynamic> json) =>
      MemberMeetupComment(
        authorName: json['author_name'] as String? ?? '',
        note: json['note'] as String? ?? '',
        writtenAt: DateTime.fromMillisecondsSinceEpoch(
          ((json['written_at_unix_seconds'] as num?)?.toInt() ?? 0) * 1000,
        ),
      );

  /// Empty when the viewer was not on the meetup.
  final String authorName;
  final String note;
  final DateTime writtenAt;
}
