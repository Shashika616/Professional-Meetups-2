// ignore_for_file: prefer_initializing_formals
// Public param names deliberately differ from private field names — see
// token_refresher.dart's own doc comment for the same tradeoff.
import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/models/paged_result.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';

/// A [MeetupService] whose responses are scripted per-call by the test —
/// unlike [MockMeetupService] (which simulates real server behavior with
/// latency for UX-level tests), this is for widget tests that need to
/// assert *which* method was called with *which* arguments, immediately.
class ScriptedMeetupService implements MeetupService {
  ScriptedMeetupService({
    List<Meetup> openMeetups = const [],
    // 2026-08-31 round-3 hardening, Fix 1 — lets a test script a second
    // page: the first (cursor == null) call returns [openMeetups] plus
    // [openMeetupsNextCursor]/[openMeetupsHasMore]; a subsequent call with
    // a non-null cursor returns [openMeetupsPage2] with no further cursor.
    // Two pages is all any test needs to prove the "load more" wiring
    // works; a fake supporting arbitrary depth would be more machinery
    // than the thing it's testing.
    String? openMeetupsNextCursor,
    bool openMeetupsHasMore = false,
    List<Meetup> openMeetupsPage2 = const [],
    // 2026-08-31 round-5 hardening — lets a test simulate a failed
    // second-page fetch (openMeetupsPage2Error, thrown instead of
    // returning openMeetupsPage2) and/or race against an in-flight one
    // (openMeetupsPage2Gate, awaited before returning/throwing — a test
    // holds the Completer and resolves it deliberately, e.g. after
    // switching the intent filter, rather than relying on a real/fake-clock
    // delay to land the race deterministically).
    Object? openMeetupsPage2Error,
    Future<void>? openMeetupsPage2Gate,
    // Thrown from the FIRST-page call, so a test can script the provider
    // into its error state. Distinct from openMeetupsPage2Error, which only
    // fails a scroll-triggered continuation.
    Object? openMeetupsError,
    // Awaited before the FIRST page returns, so a test can hold a fetch open
    // and observe what the UI does while a real network would be slow.
    Future<void>? openMeetupsGate,
    ({List<Meetup> hosted, List<Meetup> requested}) myMeetups = const (
      hosted: <Meetup>[],
      requested: <Meetup>[],
    ),
    // 2026-08-31 round-4 hardening — same two-page scripting shape as
    // openMeetups above, applied independently to each side of
    // listMyMeetups (hostedCursor null vs. non-null selects myMeetups.hosted
    // vs. myMeetupsHostedPage2; requestedCursor likewise).
    String? myMeetupsHostedNextCursor,
    bool myMeetupsHostedHasMore = false,
    List<Meetup> myMeetupsHostedPage2 = const [],
    String? myMeetupsRequestedNextCursor,
    bool myMeetupsRequestedHasMore = false,
    List<Meetup> myMeetupsRequestedPage2 = const [],
    List<MeetupRequestModel> meetupRequests = const [],
    Meetup? meetupDetail,
    SafetyState? safetyState,
    List<RatableParticipant> ratableParticipants = const [],
    List<Meetup> activeMeetups = const [],
  }) : _openMeetups = openMeetups,
       _openMeetupsNextCursor = openMeetupsNextCursor,
       _openMeetupsHasMore = openMeetupsHasMore,
       _openMeetupsPage2 = openMeetupsPage2,
       _openMeetupsPage2Error = openMeetupsPage2Error,
       _openMeetupsPage2Gate = openMeetupsPage2Gate,
       _openMeetupsError = openMeetupsError,
       _openMeetupsGate = openMeetupsGate,
       _myMeetups = myMeetups,
       _myMeetupsHostedNextCursor = myMeetupsHostedNextCursor,
       _myMeetupsHostedHasMore = myMeetupsHostedHasMore,
       _myMeetupsHostedPage2 = myMeetupsHostedPage2,
       _myMeetupsRequestedNextCursor = myMeetupsRequestedNextCursor,
       _myMeetupsRequestedHasMore = myMeetupsRequestedHasMore,
       _myMeetupsRequestedPage2 = myMeetupsRequestedPage2,
       _meetupRequests = meetupRequests,
       _meetupDetail = meetupDetail,
       _safetyState = safetyState,
       _ratableParticipants = ratableParticipants,
       _activeMeetups = activeMeetups;

  final List<Meetup> _openMeetups;
  final String? _openMeetupsNextCursor;
  final bool _openMeetupsHasMore;
  final List<Meetup> _openMeetupsPage2;
  final Object? _openMeetupsPage2Error;
  final Future<void>? _openMeetupsPage2Gate;
  final Object? _openMeetupsError;
  final Future<void>? _openMeetupsGate;
  final ({List<Meetup> hosted, List<Meetup> requested}) _myMeetups;
  final String? _myMeetupsHostedNextCursor;
  final bool _myMeetupsHostedHasMore;
  final List<Meetup> _myMeetupsHostedPage2;
  final String? _myMeetupsRequestedNextCursor;
  final bool _myMeetupsRequestedHasMore;
  final List<Meetup> _myMeetupsRequestedPage2;
  final List<MeetupRequestModel> _meetupRequests;
  final Meetup? _meetupDetail;
  final SafetyState? _safetyState;
  final List<RatableParticipant> _ratableParticipants;
  List<Meetup> _activeMeetups;

  /// Lets a test move the active list on the way the server would — e.g. a
  /// reviewed meetup dropping out of it.
  set activeMeetups(List<Meetup> value) => _activeMeetups = value;

  String? lastRequestToJoinMeetupId;
  String? lastRespondToRequestId;
  bool? lastRespondToRequestAccept;
  String? lastSubmitRatingMeetupId;
  String? lastSubmitRatingRatedUserId;
  int? lastSubmitRatingScore;
  String? lastSubmitFeedbackNotes;
  String? lastCloseMeetupId;
  Meetup? closeMeetupResult;
  String? lastCancelMeetupId;
  String? lastCancelMeetupReason;
  MeetupException? cancelMeetupError;
  String? lastWithdrawRequestId;
  String? lastWithdrawRequestNote;
  String? lastDeclineCheckInMeetupId;
  String? lastDeclineCheckInReason;
  MeetupException? declineCheckInError;
  double? lastListOpenMeetupsViewerLat;
  double? lastListOpenMeetupsViewerLng;
  // Nullable-and-recorded rather than just nullable: `null` is now a
  // meaningful VALUE on the wire ("every intent", the home filter's "All"),
  // not an absent argument, so a test asserting the All case has to be able
  // to tell "passed null" apart from "never called".
  IntentType? lastListOpenMeetupsIntent;
  int? lastListOpenMeetupsWithinDays;
  int listOpenMeetupsCallCount = 0;
  final List<String?> listOpenMeetupsCursors = [];

  @override
  Future<Meetup> createMeetup({
    required IntentType intent,
    required DateTime windowStart,
    required DateTime windowEnd,
    required double locationLat,
    required double locationLng,
    required String locationLabel,
    required int capacity,
  }) => throw UnimplementedError();

  @override
  Future<PagedResult<Meetup>> listOpenMeetups({
    IntentType? intent,
    required double viewerLat,
    required double viewerLng,
    String? cursor,
    int withinDays = 0,
  }) async {
    listOpenMeetupsCallCount++;
    lastListOpenMeetupsViewerLat = viewerLat;
    lastListOpenMeetupsViewerLng = viewerLng;
    lastListOpenMeetupsIntent = intent;
    lastListOpenMeetupsWithinDays = withinDays;
    listOpenMeetupsCursors.add(cursor);
    if (_openMeetupsGate != null) {
      await _openMeetupsGate;
    }
    if (_openMeetupsError != null) {
      throw _openMeetupsError;
    }
    if (cursor == null) {
      return PagedResult(
        items: _openMeetups,
        nextCursor: _openMeetupsNextCursor,
        hasMore: _openMeetupsHasMore,
      );
    }
    if (_openMeetupsPage2Gate != null) {
      await _openMeetupsPage2Gate;
    }
    if (_openMeetupsPage2Error != null) {
      throw _openMeetupsPage2Error;
    }
    return PagedResult(items: _openMeetupsPage2);
  }

  @override
  Future<Meetup> getMeetup(String meetupId) async => _meetupDetail!;

  int listMyMeetupsCallCount = 0;
  final List<({String? hostedCursor, String? requestedCursor})>
  listMyMeetupsCalls = [];

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
    listMyMeetupsCallCount++;
    listMyMeetupsCalls.add((
      hostedCursor: hostedCursor,
      requestedCursor: requestedCursor,
    ));
    return (
      hosted: hostedCursor == null ? _myMeetups.hosted : _myMeetupsHostedPage2,
      requested: requestedCursor == null
          ? _myMeetups.requested
          : _myMeetupsRequestedPage2,
      hostedNextCursor: hostedCursor == null
          ? _myMeetupsHostedNextCursor
          : null,
      hostedHasMore: hostedCursor == null ? _myMeetupsHostedHasMore : false,
      requestedNextCursor: requestedCursor == null
          ? _myMeetupsRequestedNextCursor
          : null,
      requestedHasMore: requestedCursor == null
          ? _myMeetupsRequestedHasMore
          : false,
    );
  }

  // Round-9 hardening — lets a test assert real-refetch behavior (pull-to-
  // refresh, app-resume) actually calls the network, and that the
  // Timer.periodic display-only tick in active_meetups_section.dart still
  // genuinely does NOT.
  int listActiveMeetupsCallCount = 0;

  /// What findScheduleConflict answers; null (the default) is a free
  /// window. [findScheduleConflictError], when set, is thrown instead.
  Meetup? scheduleConflict;
  Object? findScheduleConflictError;
  int findScheduleConflictCallCount = 0;
  DateTime? lastScheduleCheckStart;
  DateTime? lastScheduleCheckEnd;

  @override
  Future<Meetup?> findScheduleConflict({
    required DateTime windowStart,
    required DateTime windowEnd,
  }) async {
    findScheduleConflictCallCount++;
    lastScheduleCheckStart = windowStart;
    lastScheduleCheckEnd = windowEnd;
    if (findScheduleConflictError != null) throw findScheduleConflictError!;
    return scheduleConflict;
  }

  @override
  Future<List<Meetup>> listActiveMeetups() async {
    listActiveMeetupsCallCount++;
    return _activeMeetups;
  }

  @override
  Future<List<MeetupRequestModel>> listMeetupRequests(String meetupId) async =>
      _meetupRequests;

  @override
  Future<MeetupRequestModel> requestToJoin(String meetupId) async {
    lastRequestToJoinMeetupId = meetupId;
    return MeetupRequestModel(
      id: 'request-1',
      meetupId: meetupId,
      requesterId: 'me',
      requesterFullName: 'Me',
      requesterTrustLevel: 2,
      status: MeetupRequestStatus.pending,
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<void> withdrawRequest(String requestId, {String? note}) async {
    lastWithdrawRequestId = requestId;
    lastWithdrawRequestNote = note;
  }

  @override
  Future<MeetupRequestModel> respondToRequest(
    String requestId, {
    required bool accept,
  }) async {
    lastRespondToRequestId = requestId;
    lastRespondToRequestAccept = accept;
    return MeetupRequestModel(
      id: requestId,
      meetupId: 'meetup-1',
      requesterId: 'requester-1',
      requesterFullName: 'Requester',
      requesterTrustLevel: 2,
      status: accept
          ? MeetupRequestStatus.accepted
          : MeetupRequestStatus.rejected,
      createdAt: DateTime.now(),
      resolvedAt: DateTime.now(),
    );
  }

  // Round-9 hardening (ADR-030) — lets a test assert the login/session-
  // restore push-token-registration call site actually reaches this
  // method (and with what token) once a real PushNotificationService
  // exists, and that it's genuinely never called while
  // NoOpPushNotificationService.currentToken() keeps returning null.
  int registerDeviceTokenCallCount = 0;
  String? lastRegisteredDeviceToken;

  @override
  Future<void> registerDeviceToken(String fcmToken) async {
    registerDeviceTokenCallCount++;
    lastRegisteredDeviceToken = fcmToken;
  }

  @override
  Future<SafetyState> getSafetyState(String meetupId) async {
    final state = _safetyState;
    if (state == null) {
      // Matches real backend behavior (ADR-024 §3): a caller with no
      // Safety Gate row is not a participant, not "not started yet."
      throw const MeetupForbiddenException('not a participant');
    }
    return state;
  }

  @override
  Future<SafetyState> acknowledgeSafetyChecklist(String meetupId) async =>
      SafetyState(meetupId: meetupId, checklistAckAt: DateTime.now());

  @override
  Future<SafetyState> setLiveLocationOptIn(String meetupId, bool optIn) async =>
      SafetyState(meetupId: meetupId, liveLocationOptIn: optIn);

  /// Recorded so a test can assert WHICH contacts were shared with, not just
  /// that the call happened.
  final List<String> sharedContactIds = [];
  MeetupException? shareWithContactsError;

  @override
  Future<SafetyState> shareWithContacts(
    String meetupId,
    List<String> contactIds,
  ) async {
    if (shareWithContactsError != null) {
      throw shareWithContactsError!;
    }
    sharedContactIds.addAll(contactIds);
    return SafetyState(
      meetupId: meetupId,
      checklistAckAt: _safetyState?.checklistAckAt,
      checkedInAt: _safetyState?.checkedInAt,
      declinedAt: _safetyState?.declinedAt,
      declineReason: _safetyState?.declineReason,
      sharedWithContactIds: List.of(sharedContactIds),
    );
  }

  @override
  Future<SafetyState> checkIn(String meetupId) async =>
      SafetyState(meetupId: meetupId, checkedInAt: DateTime.now());

  @override
  Future<SafetyState> declineCheckIn(String meetupId, String reason) async {
    lastDeclineCheckInMeetupId = meetupId;
    lastDeclineCheckInReason = reason;
    if (declineCheckInError != null) throw declineCheckInError!;
    return SafetyState(
      meetupId: meetupId,
      declinedAt: DateTime.now(),
      declineReason: reason,
    );
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
    lastSubmitFeedbackNotes = notes;
  }

  @override
  Future<List<RatableParticipant>> listRatableParticipants(
    String meetupId,
  ) async => _ratableParticipants;

  /// The attendee list this fake serves. Defaults to empty, which makes the
  /// strip self-hide — most tests are not about participants.
  MeetupParticipants participants = const MeetupParticipants();

  @override
  Future<MeetupParticipants> listMeetupParticipants(String meetupId) async =>
      participants;

  /// The notification history this fake serves, newest-first as the server
  /// returns it.
  List<AppNotification> notifications = const [];

  /// Thrown by listNotifications when set — for the failure-path tests.
  Object? notificationsError;

  int listNotificationsCallCount = 0;

  @override
  Future<List<AppNotification>> listNotifications() async {
    listNotificationsCallCount++;
    final error = notificationsError;
    if (error != null) throw error;
    return notifications;
  }

  @override
  Future<RatableParticipants> listRatableParticipantsWithTraits(
    String meetupId,
  ) async => RatableParticipants(
    participants: _ratableParticipants,
    availableTraits: availableTraits,
  );

  /// The review flow's trait vocabulary. Defaults to a small real-shaped
  /// set so a test that doesn't care about traits still renders pickers.
  List<RatingTrait> availableTraits = const [
    RatingTrait(key: 'cheerful', label: 'Cheerful', emoji: '☀️'),
    RatingTrait(key: 'great_listener', label: 'Great listener', emoji: '👂'),
    RatingTrait(key: 'insightful', label: 'Insightful', emoji: '💡'),
    RatingTrait(key: 'funny', label: 'Funny', emoji: '😂'),
    RatingTrait(key: 'welcoming', label: 'Welcoming', emoji: '🤝'),
    RatingTrait(
      key: 'arrived_late',
      label: 'Arrived late',
      emoji: '⏰',
      negative: true,
    ),
    RatingTrait(
      key: 'distracted',
      label: 'Distracted',
      emoji: '📱',
      negative: true,
    ),
  ];

  /// What the last submitMeetupReview carried, and how many times it ran.
  int submitReviewCallCount = 0;
  int? lastReviewOverallScore;
  String? lastReviewNotes;
  List<ReviewParticipantInput> lastReviewParticipants = const [];

  /// Thrown by submitMeetupReview when set — for the failure-path tests.
  Object? submitReviewError;

  /// What getMeetupReview returns.
  MeetupReview meetupReview = const MeetupReview(completed: false);

  /// Runs after a successful submitMeetupReview, so a test can move the
  /// scripted world forward the way the real server would — the meetup
  /// leaving the active list, getMeetupReview starting to answer.
  void Function()? onSubmitReview;

  @override
  Future<void> submitMeetupReview(
    String meetupId, {
    required int overallScore,
    String? notes,
    required List<ReviewParticipantInput> participants,
  }) async {
    submitReviewCallCount++;
    lastReviewOverallScore = overallScore;
    lastReviewNotes = notes;
    lastReviewParticipants = participants;
    final error = submitReviewError;
    if (error != null) throw error;
    onSubmitReview?.call();
  }

  @override
  Future<MeetupReview> getMeetupReview(String meetupId) async => meetupReview;

  @override
  Future<void> submitRating(
    String meetupId, {
    required String ratedUserId,
    required int score,
  }) async {
    lastSubmitRatingMeetupId = meetupId;
    lastSubmitRatingRatedUserId = ratedUserId;
    lastSubmitRatingScore = score;
  }

  @override
  Future<Meetup> closeMeetup(String meetupId) async {
    lastCloseMeetupId = meetupId;
    final result = closeMeetupResult;
    if (result == null) {
      throw const MeetupNotFoundException('not found');
    }
    return result;
  }

  @override
  Future<void> cancelMeetup(String meetupId, {required String reason}) async {
    lastCancelMeetupId = meetupId;
    lastCancelMeetupReason = reason;
    final error = cancelMeetupError;
    if (error != null) throw error;
  }
}
