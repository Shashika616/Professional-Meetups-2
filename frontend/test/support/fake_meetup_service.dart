import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/models/paged_result.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';

/// A [MeetupService] that resolves everything immediately, no simulated
/// latency — for tests (HomePage/AppShell/OnboardingFlow) where
/// UpcomingMeetupCard's myMeetupsProvider read is incidental, not what the
/// test is about. [MockMeetupService]'s deliberate 400ms latency (it
/// simulates real UX timing for meetup-feature tests) is otherwise a
/// pending-Timer trap here: pumpAndSettle only keeps pumping while a frame
/// is actually scheduled, so a bare unfired Future.delayed timer left over
/// when the test ends fails the "no pending timers" invariant.
class ImmediateMeetupService implements MeetupService {
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
  }) async => const PagedResult(items: []);

  @override
  Future<Meetup> getMeetup(String meetupId) => throw UnimplementedError();

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
  listMyMeetups({String? hostedCursor, String? requestedCursor}) async => (
    hosted: <Meetup>[],
    requested: <Meetup>[],
    hostedNextCursor: null,
    hostedHasMore: false,
    requestedNextCursor: null,
    requestedHasMore: false,
  );

  @override
  Future<List<Meetup>> listActiveMeetups() async => const [];

  @override
  Future<List<MeetupRequestModel>> listMeetupRequests(String meetupId) =>
      throw UnimplementedError();

  @override
  Future<MeetupRequestModel> requestToJoin(String meetupId) =>
      throw UnimplementedError();

  @override
  Future<void> withdrawRequest(String requestId, {String? note}) =>
      throw UnimplementedError();

  @override
  Future<MeetupRequestModel> respondToRequest(
    String requestId, {
    required bool accept,
  }) => throw UnimplementedError();

  @override
  Future<void> registerDeviceToken(String fcmToken) =>
      throw UnimplementedError();

  @override
  Future<SafetyState> getSafetyState(String meetupId) =>
      throw UnimplementedError();

  @override
  Future<SafetyState> acknowledgeSafetyChecklist(String meetupId) =>
      throw UnimplementedError();

  @override
  Future<SafetyState> setLiveLocationOptIn(String meetupId, bool optIn) =>
      throw UnimplementedError();

  @override
  Future<SafetyState> checkIn(String meetupId) => throw UnimplementedError();

  @override
  Future<SafetyState> declineCheckIn(String meetupId, String reason) =>
      throw UnimplementedError();

  @override
  Future<void> submitMeetupFeedback(
    String meetupId, {
    required bool happened,
    bool? feltSafe,
    bool? profileAccurate,
    bool? wouldMeetAgain,
    String? notes,
  }) => throw UnimplementedError();

  @override
  Future<List<RatableParticipant>> listRatableParticipants(String meetupId) =>
      throw UnimplementedError();

  @override
  Future<void> submitRating(
    String meetupId, {
    required String ratedUserId,
    required int score,
  }) => throw UnimplementedError();

  @override
  Future<Meetup> closeMeetup(String meetupId) => throw UnimplementedError();

  @override
  Future<void> cancelMeetup(String meetupId, {required String reason}) =>
      throw UnimplementedError();
}
