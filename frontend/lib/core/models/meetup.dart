import 'package:flutter/foundation.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';

/// Mirrors the backend's meetup_status Postgres enum exactly
/// (db/migrations/0003_meetups.up.sql) — no client-side states that don't
/// exist server-side (frontend/meetup-scheduling-PLAN.md Step 3).
enum MeetupStatus {
  open,
  full,
  cancelled,
  completed;

  static MeetupStatus fromWire(String value) => switch (value) {
    'open' => MeetupStatus.open,
    'full' => MeetupStatus.full,
    'cancelled' => MeetupStatus.cancelled,
    'completed' => MeetupStatus.completed,
    _ => throw FormatException('Unknown meetup status: $value'),
  };
}

/// Mirrors the backend's meetup_request_status Postgres enum exactly.
enum MeetupRequestStatus {
  pending,
  accepted,
  rejected,
  withdrawn;

  static MeetupRequestStatus fromWire(String value) => switch (value) {
    'pending' => MeetupRequestStatus.pending,
    'accepted' => MeetupRequestStatus.accepted,
    'rejected' => MeetupRequestStatus.rejected,
    'withdrawn' => MeetupRequestStatus.withdrawn,
    _ => throw FormatException('Unknown meetup request status: $value'),
  };
}

/// A scheduled meetup — host-initiated, with a hard participant cap
/// (ADR-013). `windowStart`/`windowEnd` replace the old nullable
/// `scheduledFor` (ADR-016): every meetup, "today" included, now requires a
/// real time range — no more silent no-time-entered case.
@immutable
class Meetup {
  const Meetup({
    required this.id,
    required this.hostUserId,
    this.hostFullName,
    this.hostProfilePhotoUrl,
    required this.hostTrustLevel,
    this.hostRatingAverage = 0,
    this.hostRatingCount = 0,
    required this.intent,
    this.windowStart,
    this.windowEnd,
    this.locationLat,
    this.locationLng,
    this.locationLabel,
    required this.capacity,
    required this.acceptedCount,
    required this.status,
    required this.createdAt,
    this.cancelledAt,
    this.closedAt,
    this.isHostedByMe = false,
    this.myRequestStatus,
    this.myRequestId,
    this.myRequestAutoRejected = false,
    this.cancellationReason,
    this.lockedForViewer = false,
  });

  final String id;
  final String hostUserId;

  /// hostFullName/hostProfilePhotoUrl/locationLabel/locationLat/locationLng/
  /// windowStart/windowEnd are nullable (ADR-028; locationLat/locationLng
  /// added ADR-029, round-8 hardening — the coordinates were redacted
  /// server-side same as the label, but the client field stayed
  /// non-nullable `double`, silently reading back as `0.0` for a locked
  /// meetup instead of surfacing the gap) — genuinely absent, not
  /// empty-string/a meaningless timestamp/`(0, 0)`, when [lockedForViewer]
  /// is true. Both
  /// [MeetupService.listOpenMeetups] and [MeetupService.getMeetup] can
  /// produce a locked meetup (round-5 hardening closed a real bypass
  /// where getMeetup didn't redact at all); getMeetup additionally never
  /// redacts a meetup the caller already hosts or has an accepted request
  /// on, regardless of their own trust level (round-6 hardening — a
  /// participation exception, not a blanket exemption for that RPC).
  /// listMyMeetups/listActiveMeetups/createMeetup always populate these in
  /// full, since none of them carry a viewer trust level to redact
  /// against at all. Always check [lockedForViewer] before reading these
  /// fields — never assume based on which RPC produced the [Meetup].
  final String? hostFullName;
  final String? hostProfilePhotoUrl;
  final int hostTrustLevel;

  /// Post-meetup star rating aggregate (ADR-015,
  /// docs/02-domain/domain-model.md § Rating) — 0/0 for a host who's never
  /// been rated, same "no data yet" convention as an unrated
  /// [MeetupRequestModel.requesterRatingCount].
  final double hostRatingAverage;
  final int hostRatingCount;

  final IntentType intent;
  final DateTime? windowStart;
  final DateTime? windowEnd;
  final double? locationLat;
  final double? locationLng;
  final String? locationLabel;
  final int capacity;
  final int acceptedCount;
  final MeetupStatus status;
  final DateTime createdAt;
  final DateTime? cancelledAt;

  /// Set once the host calls [MeetupService.closeMeetup] (ADR-016) —
  /// independent of rating eligibility, which stays gated on each
  /// participant's own confirmed-attendance feedback (ADR-015, unchanged).
  final DateTime? closedAt;

  final bool isHostedByMe;
  final MeetupRequestStatus? myRequestStatus;

  /// The id of the request [myRequestStatus] describes (ADR-020 §4) — only
  /// populated by [MeetupService.getMeetup], null wherever [myRequestStatus]
  /// is null. Needed for the requester-side withdraw action, which takes a
  /// request id, not a meetup id.
  final String? myRequestId;

  /// Only meaningful when [myRequestStatus] is [MeetupRequestStatus.rejected]
  /// — distinguishes the host's explicit rejection from a system auto-reject
  /// (capacity filled before the host acted). Only populated on the "My
  /// Meetups" requested list, per the backend's own doc comment on this
  /// field.
  final bool myRequestAutoRejected;

  /// The host's required reason for cancelling (ADR-020 §3) — null for a
  /// meetup that was never cancelled.
  final String? cancellationReason;

  /// ADR-028 — true when the backend redacted this meetup's sensitive
  /// fields because the viewer is below its intent's required trust
  /// level. Set by [MeetupService.listOpenMeetups] and
  /// [MeetupService.getMeetup] (round-5 hardening); getMeetup never sets
  /// this for a meetup the caller already hosts or has an accepted
  /// request on (round-6 hardening's participation exception). Always
  /// false from listMyMeetups/listActiveMeetups/createMeetup, which don't
  /// carry a viewer trust level to redact against.
  final bool lockedForViewer;

  /// "Today, 3:00–5:00 PM" / "Aug 22, 6:00–8:00 PM" style display (ADR-016)
  /// — shown on every meetup card, not just stored. See
  /// [formatMeetupWindow] for the shared formatting logic (also used by the
  /// schedule flow's Review step, which has a draft window but not yet a
  /// full [Meetup]). Empty when [windowStart]/[windowEnd] are null (a
  /// locked meetup, from either listOpenMeetups or getMeetup — see
  /// [lockedForViewer]'s own doc comment) — any caller that can receive a
  /// locked meetup must check [lockedForViewer] before rendering the
  /// window instead of relying on this fallback.
  String get formattedWindow {
    final start = windowStart, end = windowEnd;
    if (start == null || end == null) return '';
    return formatMeetupWindow(start, end);
  }

  Meetup copyWith({
    MeetupStatus? status,
    DateTime? closedAt,
    DateTime? cancelledAt,
    String? cancellationReason,
  }) {
    return Meetup(
      id: id,
      hostUserId: hostUserId,
      hostFullName: hostFullName,
      hostProfilePhotoUrl: hostProfilePhotoUrl,
      hostTrustLevel: hostTrustLevel,
      hostRatingAverage: hostRatingAverage,
      hostRatingCount: hostRatingCount,
      intent: intent,
      windowStart: windowStart,
      windowEnd: windowEnd,
      locationLat: locationLat,
      locationLng: locationLng,
      locationLabel: locationLabel,
      capacity: capacity,
      acceptedCount: acceptedCount,
      status: status ?? this.status,
      createdAt: createdAt,
      cancelledAt: cancelledAt ?? this.cancelledAt,
      closedAt: closedAt ?? this.closedAt,
      isHostedByMe: isHostedByMe,
      myRequestStatus: myRequestStatus,
      myRequestId: myRequestId,
      myRequestAutoRejected: myRequestAutoRejected,
      cancellationReason: cancellationReason ?? this.cancellationReason,
      lockedForViewer: lockedForViewer,
    );
  }

  factory Meetup.fromJson(Map<String, dynamic> json) {
    return Meetup(
      id: json['id'] as String,
      hostUserId: json['host_user_id'] as String,
      // Genuinely null (not `?? ''`) when the field is absent — ADR-028's
      // redaction sends it absent, and defaulting to '' here would make a
      // locked meetup indistinguishable from a real "no photo"/"no name"
      // case. lockedForViewer below is the field to check.
      hostFullName: json['host_full_name'] as String?,
      hostProfilePhotoUrl: json['host_profile_photo_url'] as String?,
      hostTrustLevel: json['host_trust_level'] as int? ?? 0,
      hostRatingAverage: (json['host_rating_average'] as num?)?.toDouble() ?? 0,
      hostRatingCount: json['host_rating_count'] as int? ?? 0,
      intent: IntentType.fromWire(json['intent'] as String),
      windowStart: _secondsToDateTime(json['window_start_unix_seconds']),
      windowEnd: _secondsToDateTime(json['window_end_unix_seconds']),
      locationLat: (json['location_lat'] as num?)?.toDouble(),
      locationLng: (json['location_lng'] as num?)?.toDouble(),
      locationLabel: json['location_label'] as String?,
      capacity: json['capacity'] as int,
      acceptedCount: json['accepted_count'] as int? ?? 0,
      status: MeetupStatus.fromWire(json['status'] as String),
      lockedForViewer: json['locked_for_viewer'] as bool? ?? false,
      createdAt:
          _secondsToDateTime(json['created_at_unix_seconds']) ?? DateTime.now(),
      cancelledAt: _secondsToDateTime(json['cancelled_at_unix_seconds']),
      closedAt: _secondsToDateTime(json['closed_at_unix_seconds']),
      isHostedByMe: json['is_hosted_by_me'] as bool? ?? false,
      myRequestStatus: json['my_request_status'] != null
          ? MeetupRequestStatus.fromWire(json['my_request_status'] as String)
          : null,
      myRequestId: json['my_request_id'] as String?,
      myRequestAutoRejected: json['my_request_auto_rejected'] as bool? ?? false,
      cancellationReason: json['cancellation_reason'] as String?,
    );
  }
}

const _monthAbbr = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "Today, 3:00–5:00 PM" / "Aug 22, 6:00–8:00 PM" style display (ADR-016) —
/// a top-level function (not just [Meetup.formattedWindow]) so the
/// schedule flow's Review step can format a draft window before a full
/// [Meetup] exists yet. The date shown is [start]'s; a window is allowed to
/// cross midnight (e.g. "10:00 PM–1:00 AM" is valid, nothing in ADR-016
/// requires same-day), in which case both times carry their own AM/PM
/// suffix — otherwise the suffix is shown once, at the end.
String formatMeetupWindow(DateTime start, DateTime end) {
  final now = DateTime.now();
  final isToday =
      start.year == now.year &&
      start.month == now.month &&
      start.day == now.day;
  final datePart = isToday
      ? 'Today'
      : '${_monthAbbr[start.month - 1]} ${start.day}';
  final startIsPM = start.hour >= 12;
  final endIsPM = end.hour >= 12;
  final rangePart = startIsPM == endIsPM
      ? '${_formatTime(start, showPeriod: false)}–${_formatTime(end)}'
      : '${_formatTime(start)}–${_formatTime(end)}';
  return '$datePart, $rangePart';
}

/// Formats [time] as "3:00 PM" (or "3:00" with [showPeriod] false, for the
/// start of a same-AM/PM-period range where the end already carries the
/// suffix).
String _formatTime(DateTime time, {bool showPeriod = true}) {
  final hour24 = time.hour;
  final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
  final minute = time.minute.toString().padLeft(2, '0');
  if (!showPeriod) return '$hour12:$minute';
  final period = hour24 >= 12 ? 'PM' : 'AM';
  return '$hour12:$minute $period';
}

/// Another user's request to join a [Meetup].
@immutable
class MeetupRequestModel {
  const MeetupRequestModel({
    required this.id,
    required this.meetupId,
    required this.requesterId,
    required this.requesterFullName,
    this.requesterProfilePhotoUrl = '',
    required this.requesterTrustLevel,
    this.requesterRatingAverage = 0,
    this.requesterRatingCount = 0,
    required this.status,
    this.autoRejected = false,
    required this.createdAt,
    this.resolvedAt,
    this.withdrawalNote,
    this.checkedInAt,
    this.declinedAt,
    this.declineReason,
  });

  final String id;
  final String meetupId;
  final String requesterId;
  final String requesterFullName;
  final String requesterProfilePhotoUrl;
  final int requesterTrustLevel;

  /// Post-meetup star rating aggregate (ADR-015) — 0/0 for a requester
  /// who's never been rated.
  final double requesterRatingAverage;
  final int requesterRatingCount;

  final MeetupRequestStatus status;
  final bool autoRejected;
  final DateTime createdAt;
  final DateTime? resolvedAt;

  /// The requester's optional note left when withdrawing (ADR-020 §4) —
  /// null unless [status] is [MeetupRequestStatus.withdrawn] and one was
  /// given. Shown to the host as context for the withdrawal-triggered
  /// rating.
  final String? withdrawalNote;

  /// Host visibility into this accepted participant's Safety Gate status
  /// (ADR-024 §6) — set only for an accepted request whose participant has
  /// checked in or declined; null for pending/rejected/withdrawn requests,
  /// which never get a `meetup_safety_state` row. [declinedAt]/
  /// [declineReason] are set together, mutually exclusive with
  /// [checkedInAt].
  final DateTime? checkedInAt;
  final DateTime? declinedAt;
  final String? declineReason;

  factory MeetupRequestModel.fromJson(Map<String, dynamic> json) {
    return MeetupRequestModel(
      id: json['id'] as String,
      meetupId: json['meetup_id'] as String,
      requesterId: json['requester_id'] as String,
      requesterFullName: json['requester_full_name'] as String? ?? '',
      requesterProfilePhotoUrl:
          json['requester_profile_photo_url'] as String? ?? '',
      requesterTrustLevel: json['requester_trust_level'] as int? ?? 0,
      requesterRatingAverage:
          (json['requester_rating_average'] as num?)?.toDouble() ?? 0,
      requesterRatingCount: json['requester_rating_count'] as int? ?? 0,
      status: MeetupRequestStatus.fromWire(json['status'] as String),
      autoRejected: json['auto_rejected'] as bool? ?? false,
      createdAt:
          _secondsToDateTime(json['created_at_unix_seconds']) ?? DateTime.now(),
      resolvedAt: _secondsToDateTime(json['resolved_at_unix_seconds']),
      withdrawalNote: json['withdrawal_note'] as String?,
      checkedInAt: _secondsToDateTime(json['checked_in_at_unix_seconds']),
      declinedAt: _secondsToDateTime(json['declined_at_unix_seconds']),
      declineReason: json['decline_reason'] as String?,
    );
  }
}

/// The caller's own Safety Gate progress on one meetup (ADR-013 § 3, Safety
/// UX Flows.md; per-participant since ADR-024 — this is always the caller's
/// own row, never another participant's).
@immutable
class SafetyState {
  const SafetyState({
    required this.meetupId,
    this.checklistAckAt,
    this.liveLocationOptIn = false,
    this.checkedInAt,
    this.declinedAt,
    this.declineReason,
    this.sharedWithContactIds = const [],
  });

  final String meetupId;
  final DateTime? checklistAckAt;
  final bool liveLocationOptIn;
  final DateTime? checkedInAt;

  /// Set together, mutually exclusive with [checkedInAt] (ADR-024 §4) — the
  /// backend enforces this; the client never needs to reconcile both being
  /// set at once.
  final DateTime? declinedAt;
  final String? declineReason;

  /// Trusted contacts already told about this meetup by the viewer.
  ///
  /// Server-sourced on every safety-state read, so reopening the screen shows
  /// what was actually done. That confirmation is the point of the feature —
  /// a safety action you cannot verify afterwards is one you cannot rely on.
  final List<String> sharedWithContactIds;

  bool get sharedWithAnyContact => sharedWithContactIds.isNotEmpty;

  bool get checklistAcknowledged => checklistAckAt != null;
  bool get checkedIn => checkedInAt != null;
  bool get declined => declinedAt != null;

  factory SafetyState.fromJson(Map<String, dynamic> json) {
    return SafetyState(
      meetupId: json['meetup_id'] as String,
      checklistAckAt: _secondsToDateTime(json['checklist_ack_at_unix_seconds']),
      liveLocationOptIn: json['live_location_opt_in'] as bool? ?? false,
      checkedInAt: _secondsToDateTime(json['checked_in_at_unix_seconds']),
      declinedAt: _secondsToDateTime(json['declined_at_unix_seconds']),
      declineReason: json['decline_reason'] as String?,
      // The server always emits this key (never omitempty — see the
      // gateway's safetyStateResponse), but it is read defensively anyway so
      // an older build reads as "told nobody" rather than throwing.
      sharedWithContactIds:
          (json['shared_with_contact_ids'] as List<dynamic>?)?.cast<String>() ??
          const [],
    );
  }
}

/// Another participant of a meetup the viewer can (or already did) rate
/// (ADR-015, docs/02-domain/domain-model.md § Rating) — returned by
/// [MeetupService.listRatableParticipants].
@immutable
class RatableParticipant {
  const RatableParticipant({
    required this.userId,
    required this.fullName,
    this.profilePhotoUrl = '',
    required this.trustLevel,
    this.alreadyRated = false,
    this.contextNote,
  });

  final String userId;
  final String fullName;
  final String profilePhotoUrl;
  final int trustLevel;
  final bool alreadyRated;

  /// The withdrawal note, when this entry is a withdrawal-triggered rating
  /// target (ADR-020 §4) — null for the happened-based and
  /// cancellation-triggered entries, which carry no such context.
  final String? contextNote;

  factory RatableParticipant.fromJson(Map<String, dynamic> json) {
    return RatableParticipant(
      userId: json['user_id'] as String,
      fullName: json['full_name'] as String? ?? '',
      profilePhotoUrl: json['profile_photo_url'] as String? ?? '',
      trustLevel: json['trust_level'] as int? ?? 0,
      alreadyRated: json['already_rated'] as bool? ?? false,
      contextNote: json['context_note'] as String?,
    );
  }
}

DateTime? _secondsToDateTime(Object? value) {
  if (value == null) return null;
  return DateTime.fromMillisecondsSinceEpoch((value as int) * 1000);
}
