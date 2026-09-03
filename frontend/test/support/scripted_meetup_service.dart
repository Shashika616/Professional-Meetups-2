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
  final List<Meetup> _activeMeetups;

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
    required IntentType intent,
    required double viewerLat,
    required double viewerLng,
    String? cursor,
  }) async {
    listOpenMeetupsCallCount++;
    lastListOpenMeetupsViewerLat = viewerLat;
    lastListOpenMeetupsViewerLng = viewerLng;
    listOpenMeetupsCursors.add(cursor);
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
