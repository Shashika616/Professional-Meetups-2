import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/models/paged_result.dart';

/// Contract for host-initiated meetup scheduling and join requests
/// (ADR-013). Same `abstract interface class` + `Mock*`-for-tests pattern
/// as [AuthService] — see `CLAUDE.md`'s "Service-contract pattern". Methods
/// map 1:1 to the backend's RPCs (backend/meetup-scheduling-PLAN.md Step C).
///
/// The client never decides trust or capacity — it only displays what the
/// server returns; every gate (trust level, capacity, ownership) is
/// re-checked server-side regardless of what this app's own UI already
/// disables.
abstract interface class MeetupService {
  Future<Meetup> createMeetup({
    required IntentType intent,
    required DateTime windowStart,
    required DateTime windowEnd,
    required double locationLat,
    required double locationLng,
    required String locationLabel,
    required int capacity,
  });

  /// cursor null means the first page. [viewerLat]/[viewerLng] are
  /// required (ADR-021 §2) — the browse screen's on-demand location read;
  /// there is no unfiltered fallback, the caller must have a fresh
  /// coordinate before calling this at all.
  /// [intent] null means EVERY intent — Home's "All" filter. [withinDays]
  /// 0 means no time restriction; Home's "Happening Soon" passes 7. Both
  /// default to the pre-existing behaviour, so nothing that called this
  /// before needs to change.
  Future<PagedResult<Meetup>> listOpenMeetups({
    IntentType? intent,
    required double viewerLat,
    required double viewerLng,
    String? cursor,
    int withinDays = 0,
  });

  Future<Meetup> getMeetup(String meetupId);

  /// Returns (hosted, requested) — kept separate rather than one merged
  /// list, matching the backend's ListMyMeetups response shape. Hosted and
  /// requested paginate independently (2026-08-31 round-4 hardening) —
  /// unrelated sets, separate cursors, `hostedCursor null`/
  /// `requestedCursor null` each mean "first page" for that side alone.
  Future<
    ({
      List<Meetup> hosted,
      List<Meetup> requested,
      String? hostedNextCursor,
      bool hostedHasMore,
      String? requestedNextCursor,
      bool requestedHasMore,
    })
  >
  listMyMeetups({String? hostedCursor, String? requestedCursor});

  /// Meetups where the caller is host or an accepted participant, merged
  /// and server-sorted soonest-`windowStart`-first (ADR-025 §2) — backs
  /// HomePage's "Active Meetups" section and the persistent swipeable
  /// card. Unlike [listMyMeetups]'s Hosted/Requested split, this is
  /// already one merged list — the server, not this client, decides what
  /// counts as active (`status IN ('open','full') AND window_end >=
  /// now()`); the persistent-card eligibility window on top of that
  /// (`windowStart - 30min <= now <= windowEnd`) is presentational only,
  /// computed client-side from the returned timestamps.
  Future<List<Meetup>> listActiveMeetups();

  /// The host's request-management view — every request (any status) on
  /// meetupId, with requester display info.
  Future<List<MeetupRequestModel>> listMeetupRequests(String meetupId);

  Future<MeetupRequestModel> requestToJoin(String meetupId);

  /// Withdraws requestId — both pending and accepted requests are
  /// withdrawable (ADR-020 §4). [note] is optional context shown to the
  /// host, who may rate the requester once for the withdrawal
  /// (IsEligibleForWithdrawalRating).
  Future<void> withdrawRequest(String requestId, {String? note});

  Future<MeetupRequestModel> respondToRequest(
    String requestId, {
    required bool accept,
  });

  Future<void> registerDeviceToken(String fcmToken);

  /// Every Safety Gate call below identifies the caller from the signed-in
  /// session's own token, never a parameter this class exposes — same
  /// discipline as every other authenticated call in this app. Throws
  /// [MeetupForbiddenException] if the caller isn't this meetup's host or
  /// an accepted requester on it (ADR-024 §3) — the row is only ever
  /// created for an actual participant (at meetup creation for the host, at
  /// accept-time for an accepted requester), so this should never be
  /// reachable through this app's own navigation; a caller reaching here
  /// anyway is a real authorization rejection, not a "not started yet"
  /// state to route around.
  Future<SafetyState> getSafetyState(String meetupId);
  Future<SafetyState> acknowledgeSafetyChecklist(String meetupId);
  Future<SafetyState> setLiveLocationOptIn(String meetupId, bool optIn);

  /// Tells the caller's chosen trusted contacts where and when this meetup
  /// is.
  ///
  /// [contactIds] must be the caller's own contacts — the server rejects any
  /// that are not, so a guessed id cannot reach a stranger. Nothing about
  /// the message is client-supplied: the server builds it from the meetup
  /// row.
  ///
  /// Idempotent per contact: re-sharing with someone who already knows does
  /// not text them twice.
  Future<SafetyState> shareWithContacts(
    String meetupId,
    List<String> contactIds,
  );
  Future<SafetyState> checkIn(String meetupId);

  /// Declines the safety checklist/check-in stage instead of silently not
  /// checking in (ADR-024 §4). [reason] is required — rejected server-side
  /// if empty. Mutually exclusive with [checkIn]: throws
  /// [MeetupConflictException] if the caller already checked in (and vice
  /// versa, calling [checkIn] after this throws the same way). Notifies the
  /// host on success.
  Future<SafetyState> declineCheckIn(String meetupId, String reason);
  Future<void> submitMeetupFeedback(
    String meetupId, {
    required bool happened,
    bool? feltSafe,
    bool? profileAccurate,
    bool? wouldMeetAgain,
    String? notes,
  });

  /// The other participants (host + accepted requesters, excluding the
  /// caller) of a meetup the caller can rate — each flagged with whether
  /// the caller already rated them (ADR-015,
  /// docs/02-domain/domain-model.md § Rating). As of ADR-020, this also
  /// surfaces two further cases beyond the original happened-based one: a
  /// cancelled meetup's previously-accepted requesters can rate the host,
  /// and a host can rate a specific withdrawn requester (returned with a
  /// [RatableParticipant.contextNote] carrying their withdrawal note) —
  /// reachable without ever calling [submitMeetupFeedback].
  Future<List<RatableParticipant>> listRatableParticipants(String meetupId);

  /// Rates ratedUserId 1-5 for meetupId. Throws [MeetupForbiddenException]
  /// unless one of three eligibility paths holds (ADR-020): the caller
  /// confirmed (submitMeetupFeedback, happened=true) that the meetup
  /// happened; the meetup was cancelled and the caller was a previously-
  /// accepted requester rating the host; or the caller is the host rating a
  /// requester whose request was withdrawn. Throws
  /// [MeetupConflictException] on a duplicate submission for the same
  /// pair.
  Future<void> submitRating(
    String meetupId, {
    required String ratedUserId,
    required int score,
  });

  /// Host-only "meetup is done" action (ADR-016), reviving the previously-
  /// unused `completed` status. Throws [MeetupForbiddenException] if the
  /// caller isn't the host or the window hasn't started yet, and
  /// [MeetupConflictException] if the meetup is already closed/cancelled.
  /// Independent of rating eligibility — closing has zero effect on who can
  /// rate whom (ADR-015's `meetup_feedback.happened` gate is unchanged).
  Future<Meetup> closeMeetup(String meetupId);

  /// Cancels meetupId. [reason] is required (ADR-020 §3) and is shown to
  /// every accepted requester, who is notified and — once the meetup is
  /// cancelled — becomes eligible to rate the host once
  /// (IsEligibleForCancellationRating). Unlike the pre-ADR-020 behavior,
  /// cancelling with accepted participants is now allowed, not rejected.
  Future<void> cancelMeetup(String meetupId, {required String reason});
}

/// Typed errors a [MeetupService] can throw — mirrors [AuthException]'s
/// shape so the UI can show a real message instead of a generic failure.
sealed class MeetupException implements Exception {
  const MeetupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 403 — the caller's trust level doesn't meet the intent's floor, or
/// they're not the host/requester an action requires.
class MeetupForbiddenException extends MeetupException {
  const MeetupForbiddenException(super.message);
}

/// 409 — a state conflict: meetup full/cancelled, request already
/// resolved, already requested to join, checklist not acknowledged before
/// check-in.
class MeetupConflictException extends MeetupException {
  const MeetupConflictException(super.message);
}

/// 404 — the meetup or request no longer exists.
class MeetupNotFoundException extends MeetupException {
  const MeetupNotFoundException(super.message);
}

/// 401 — same meaning as [AuthService]'s SessionExpiredException; kept as
/// a separate type in this file so `meetup_service.dart` doesn't need to
/// import `auth_service.dart` just for one exception type.
class MeetupSessionExpiredException extends MeetupException {
  const MeetupSessionExpiredException(super.message);
}

/// The server was reached and answered with something the client could not
/// use — a 400, a 5xx, an unparseable body. NOT a connectivity problem: the
/// request got there.
class MeetupNetworkException extends MeetupException {
  const MeetupNetworkException([
    super.message = 'Something went wrong. Please try again.',
  ]);
}

/// The request never reached the server at all — no connection, DNS failure,
/// or a timeout.
///
/// # WHY THIS IS ITS OWN TYPE
///
/// [MeetupNetworkException] is named as if it meant this, but it is thrown
/// for a 400 and for every unmapped status including 5xx — cases where the
/// server very much was reached. A transport failure, meanwhile, used to
/// escape as a raw `SocketException`/`http.ClientException` and never became
/// a [MeetupException] at all.
///
/// So the UI had no way to tell "you are offline" from "the server rejected
/// this", and screens that wanted to say the former had to say it for both.
/// Anything user-facing that offers a "check your connection" message should
/// key on THIS type and nothing else.
class MeetupOfflineException extends MeetupException {
  const MeetupOfflineException([
    super.message = 'No connection. Check your network and try again.',
  ]);
}

/// Simulates server latency for widget tests — kept in the codebase for
/// that purpose even though [HttpMeetupService] is what `app_providers.dart`
/// wires up for real use (mirrors MockAuthService's own doc comment).
class MockMeetupService implements MeetupService {
  static const Duration latency = Duration(milliseconds: 400);

  final List<Meetup> _meetups = [];
  final List<MeetupRequestModel> _requests = [];
  final Map<String, SafetyState> _safetyStates = {};
  int _nextId = 0;

  Meetup _mockMeetup(IntentType intent) => Meetup(
    id: 'mock-meetup-${_nextId++}',
    hostUserId: 'mock-host',
    hostFullName: 'Mock Host',
    hostTrustLevel: 2,
    intent: intent,
    windowStart: DateTime.now().add(const Duration(hours: 1)),
    windowEnd: DateTime.now().add(const Duration(hours: 3)),
    locationLat: 6.9271,
    locationLng: 79.8612,
    locationLabel: 'Mock Cafe',
    capacity: 2,
    acceptedCount: 0,
    status: MeetupStatus.open,
    createdAt: DateTime.now(),
  );

  @override
  Future<Meetup> createMeetup({
    required IntentType intent,
    required DateTime windowStart,
    required DateTime windowEnd,
    required double locationLat,
    required double locationLng,
    required String locationLabel,
    required int capacity,
  }) async {
    await Future<void>.delayed(latency);
    final meetup = Meetup(
      id: 'mock-meetup-${_nextId++}',
      hostUserId: 'mock-host',
      hostFullName: 'Mock Host',
      hostTrustLevel: 2,
      intent: intent,
      windowStart: windowStart,
      windowEnd: windowEnd,
      locationLat: locationLat,
      locationLng: locationLng,
      locationLabel: locationLabel,
      capacity: capacity,
      acceptedCount: 0,
      status: MeetupStatus.open,
      createdAt: DateTime.now(),
      isHostedByMe: true,
    );
    _meetups.add(meetup);
    return meetup;
  }

  @override
  Future<PagedResult<Meetup>> listOpenMeetups({
    IntentType? intent,
    required double viewerLat,
    required double viewerLng,
    String? cursor,
    int withinDays = 0,
  }) async {
    // viewerLat/viewerLng/withinDays ignored — mock data is small/static,
    // same no-op-but-accepts-the-parameter treatment MockAuthService gives
    // params it doesn't need to act on, so call sites compile identically
    // to HttpMeetupService.
    await Future<void>.delayed(latency);
    if (_meetups.isEmpty) {
      _meetups.add(_mockMeetup(intent ?? IntentType.coffee));
    }
    return PagedResult(
      // A null intent is Home's "All" — every intent, not "an intent that
      // is null". Filtering on equality here would have made the mock's
      // default view silently empty.
      items: intent == null
          ? List.of(_meetups)
          : _meetups.where((m) => m.intent == intent).toList(),
    );
  }

  @override
  Future<Meetup> getMeetup(String meetupId) async {
    await Future<void>.delayed(latency);
    return _meetups.firstWhere(
      (m) => m.id == meetupId,
      orElse: () => throw const MeetupNotFoundException('Meetup not found.'),
    );
  }

  @override
  Future<
    ({
      List<Meetup> hosted,
      List<Meetup> requested,
      String? hostedNextCursor,
      bool hostedHasMore,
      String? requestedNextCursor,
      bool requestedHasMore,
    })
  >
  listMyMeetups({String? hostedCursor, String? requestedCursor}) async {
    await Future<void>.delayed(latency);
    // Mock data is small/static — always a single complete page for both
    // sides, same no-pagination-needed treatment this mock already gives
    // listOpenMeetups above.
    return (
      hosted: _meetups.where((m) => m.isHostedByMe).toList(),
      requested: <Meetup>[],
      hostedNextCursor: null,
      hostedHasMore: false,
      requestedNextCursor: null,
      requestedHasMore: false,
    );
  }

  @override
  Future<List<Meetup>> listActiveMeetups() async {
    await Future<void>.delayed(latency);
    final now = DateTime.now();
    // windowStart/windowEnd are only ever null for a locked ListOpenMeetups
    // result (ADR-028) — this mock's own seeded _meetups never carry that,
    // so `!` here just documents that guarantee rather than defending
    // against a case that can't happen for this service.
    final active =
        _meetups
            .where(
              (m) =>
                  (m.status == MeetupStatus.open ||
                      m.status == MeetupStatus.full) &&
                  m.windowEnd!.isAfter(now),
            )
            .toList()
          ..sort((a, b) => a.windowStart!.compareTo(b.windowStart!));
    return active;
  }

  @override
  Future<List<MeetupRequestModel>> listMeetupRequests(String meetupId) async {
    await Future<void>.delayed(latency);
    return _requests.where((r) => r.meetupId == meetupId).toList();
  }

  @override
  Future<MeetupRequestModel> requestToJoin(String meetupId) async {
    await Future<void>.delayed(latency);
    final request = MeetupRequestModel(
      id: 'mock-request-${_nextId++}',
      meetupId: meetupId,
      requesterId: 'mock-requester',
      requesterFullName: 'Mock Requester',
      requesterTrustLevel: 2,
      status: MeetupRequestStatus.pending,
      createdAt: DateTime.now(),
    );
    _requests.add(request);
    return request;
  }

  @override
  Future<void> withdrawRequest(String requestId, {String? note}) async {
    await Future<void>.delayed(latency);
  }

  @override
  Future<MeetupRequestModel> respondToRequest(
    String requestId, {
    required bool accept,
  }) async {
    await Future<void>.delayed(latency);
    return MeetupRequestModel(
      id: requestId,
      meetupId: 'mock-meetup-0',
      requesterId: 'mock-requester',
      requesterFullName: 'Mock Requester',
      requesterTrustLevel: 2,
      status: accept
          ? MeetupRequestStatus.accepted
          : MeetupRequestStatus.rejected,
      createdAt: DateTime.now(),
      resolvedAt: DateTime.now(),
    );
  }

  @override
  Future<void> registerDeviceToken(String fcmToken) async {
    await Future<void>.delayed(latency);
  }

  @override
  Future<SafetyState> getSafetyState(String meetupId) async {
    await Future<void>.delayed(latency);
    final state = _safetyStates[meetupId];
    if (state == null) {
      throw const MeetupForbiddenException(
        'You are not a participant of this meetup.',
      );
    }
    return state;
  }

  @override
  Future<SafetyState> acknowledgeSafetyChecklist(String meetupId) async {
    await Future<void>.delayed(latency);
    final state = SafetyState(
      meetupId: meetupId,
      checklistAckAt: DateTime.now(),
    );
    _safetyStates[meetupId] = state;
    return state;
  }

  @override
  Future<SafetyState> setLiveLocationOptIn(String meetupId, bool optIn) async {
    await Future<void>.delayed(latency);
    final current = _safetyStates[meetupId] ?? SafetyState(meetupId: meetupId);
    final state = SafetyState(
      meetupId: meetupId,
      checklistAckAt: current.checklistAckAt,
      liveLocationOptIn: optIn,
      checkedInAt: current.checkedInAt,
    );
    _safetyStates[meetupId] = state;
    return state;
  }

  @override
  Future<SafetyState> shareWithContacts(
    String meetupId,
    List<String> contactIds,
  ) async {
    await Future<void>.delayed(latency);
    final current = _safetyStates[meetupId] ?? SafetyState(meetupId: meetupId);
    // Union, not replace — sharing with one more contact later must add to
    // the set, matching the server's per-contact upsert.
    final merged = {...current.sharedWithContactIds, ...contactIds}.toList();
    final state = SafetyState(
      meetupId: meetupId,
      checklistAckAt: current.checklistAckAt,
      liveLocationOptIn: current.liveLocationOptIn,
      checkedInAt: current.checkedInAt,
      declinedAt: current.declinedAt,
      declineReason: current.declineReason,
      sharedWithContactIds: merged,
    );
    _safetyStates[meetupId] = state;
    return state;
  }

  @override
  Future<SafetyState> checkIn(String meetupId) async {
    await Future<void>.delayed(latency);
    final current = _safetyStates[meetupId];
    if (current == null || !current.checklistAcknowledged) {
      throw const MeetupConflictException(
        'Acknowledge the safety checklist before checking in.',
      );
    }
    final state = SafetyState(
      meetupId: meetupId,
      checklistAckAt: current.checklistAckAt,
      liveLocationOptIn: current.liveLocationOptIn,
      checkedInAt: DateTime.now(),
    );
    _safetyStates[meetupId] = state;
    return state;
  }

  @override
  Future<SafetyState> declineCheckIn(String meetupId, String reason) async {
    await Future<void>.delayed(latency);
    if (reason.trim().isEmpty) {
      throw const MeetupNetworkException('A reason is required.');
    }
    final current = _safetyStates[meetupId];
    if (current != null && current.checkedIn) {
      throw const MeetupConflictException(
        'Cannot decline after already checking in.',
      );
    }
    final state = SafetyState(
      meetupId: meetupId,
      checklistAckAt: current?.checklistAckAt,
      liveLocationOptIn: current?.liveLocationOptIn ?? false,
      declinedAt: DateTime.now(),
      declineReason: reason,
    );
    _safetyStates[meetupId] = state;
    return state;
  }

  @override
  Future<void> submitMeetupFeedback(
    String meetupId, {
    required bool happened,
    bool? feltSafe,
    bool? profileAccurate,
    bool? wouldMeetAgain,
    String? notes,
  }) async {
    await Future<void>.delayed(latency);
  }

  @override
  Future<List<RatableParticipant>> listRatableParticipants(
    String meetupId,
  ) async {
    await Future<void>.delayed(latency);
    return const [];
  }

  @override
  Future<void> submitRating(
    String meetupId, {
    required String ratedUserId,
    required int score,
  }) async {
    await Future<void>.delayed(latency);
  }

  @override
  Future<Meetup> closeMeetup(String meetupId) async {
    await Future<void>.delayed(latency);
    final index = _meetups.indexWhere((m) => m.id == meetupId);
    if (index == -1) {
      throw const MeetupNotFoundException('Meetup not found.');
    }
    final closed = _meetups[index].copyWith(
      status: MeetupStatus.completed,
      closedAt: DateTime.now(),
    );
    _meetups[index] = closed;
    return closed;
  }

  @override
  Future<void> cancelMeetup(String meetupId, {required String reason}) async {
    await Future<void>.delayed(latency);
  }
}
