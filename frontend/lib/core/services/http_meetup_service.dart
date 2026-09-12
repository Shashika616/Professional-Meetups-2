import 'dart:async' show TimeoutException;
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

import 'package:professional_connections_platform/core/config/app_config.dart';
import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/models/paged_result.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';

/// Real [MeetupService] wired to the gateway's `/v1/meetups/*` REST contract
/// (backend/meetup-scheduling-PLAN.md Step D). Same
/// getAccessToken-via-TokenRefresher wiring as [HttpAuthService] — holds no
/// session state of its own.
class HttpMeetupService implements MeetupService {
  HttpMeetupService({
    http.Client? httpClient,
    String? baseUrl,
    Future<String?> Function()? getAccessToken,
  }) : _httpClient = httpClient ?? http.Client(),
       _baseUrl = baseUrl ?? AppConfig.gatewayBaseUrl,
       _getAccessToken = getAccessToken ?? (() async => null);

  final http.Client _httpClient;
  final String _baseUrl;
  final Future<String?> Function() _getAccessToken;

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
    final response = await _authenticatedPost('/v1/meetups', {
      'intent': intent.wireValue,
      'window_start_unix_seconds': windowStart.millisecondsSinceEpoch ~/ 1000,
      'window_end_unix_seconds': windowEnd.millisecondsSinceEpoch ~/ 1000,
      'location_lat': locationLat,
      'location_lng': locationLng,
      'location_label': locationLabel,
      'capacity': capacity,
    });
    return Meetup.fromJson(_decodeOrThrow(response));
  }

  @override
  Future<PagedResult<Meetup>> listOpenMeetups({
    IntentType? intent,
    required double viewerLat,
    required double viewerLng,
    String? cursor,
    int withinDays = 0,
  }) async {
    // Both new filters are OMITTED from the query when unset rather than
    // sent as an empty/zero value: the gateway reads an absent parameter as
    // "no restriction", so omission and the default agree by construction
    // instead of relying on two sides interpreting "" and 0 the same way.
    final query = {
      if (intent != null) 'intent': intent.wireValue,
      'viewer_lat': viewerLat.toString(),
      'viewer_lng': viewerLng.toString(),
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      if (withinDays > 0) 'within_days': withinDays.toString(),
    };
    final response = await _authenticatedGet('/v1/meetups', query: query);
    final decoded = _decodeOrThrow(response);
    final meetups = (decoded['meetups'] as List<dynamic>)
        .map((e) => Meetup.fromJson(e as Map<String, dynamic>))
        .toList();
    final nextCursor = decoded['next_cursor'] as String?;
    return PagedResult(
      items: meetups,
      nextCursor: (nextCursor?.isEmpty ?? true) ? null : nextCursor,
      hasMore: nextCursor != null && nextCursor.isNotEmpty,
    );
  }

  @override
  Future<Meetup> getMeetup(String meetupId) async {
    final response = await _authenticatedGet('/v1/meetups/$meetupId');
    return Meetup.fromJson(_decodeOrThrow(response));
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
    final query = {
      if (hostedCursor != null && hostedCursor.isNotEmpty)
        'hosted_cursor': hostedCursor,
      if (requestedCursor != null && requestedCursor.isNotEmpty)
        'requested_cursor': requestedCursor,
    };
    final response = await _authenticatedGet('/v1/meetups/mine', query: query);
    final decoded = _decodeOrThrow(response);
    Meetup toMeetup(Object? e) => Meetup.fromJson(e as Map<String, dynamic>);
    final hostedNextCursor = decoded['hosted_next_cursor'] as String?;
    final requestedNextCursor = decoded['requested_next_cursor'] as String?;
    return (
      hosted: (decoded['hosted'] as List<dynamic>).map(toMeetup).toList(),
      requested: (decoded['requested'] as List<dynamic>).map(toMeetup).toList(),
      hostedNextCursor: (hostedNextCursor?.isEmpty ?? true)
          ? null
          : hostedNextCursor,
      hostedHasMore: decoded['hosted_has_more'] as bool? ?? false,
      requestedNextCursor: (requestedNextCursor?.isEmpty ?? true)
          ? null
          : requestedNextCursor,
      requestedHasMore: decoded['requested_has_more'] as bool? ?? false,
    );
  }

  @override
  Future<List<Meetup>> listActiveMeetups() async {
    final response = await _authenticatedGet('/v1/meetups/active');
    final decoded = _decodeOrThrow(response);
    return (decoded['meetups'] as List<dynamic>)
        .map((e) => Meetup.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<MeetupRequestModel>> listMeetupRequests(String meetupId) async {
    final response = await _authenticatedGet('/v1/meetups/$meetupId/requests');
    final decoded = _decodeOrThrow(response);
    return (decoded['requests'] as List<dynamic>)
        .map((e) => MeetupRequestModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<MeetupRequestModel> requestToJoin(String meetupId) async {
    final response = await _authenticatedPost(
      '/v1/meetups/$meetupId/requests',
      const {},
    );
    return MeetupRequestModel.fromJson(_decodeOrThrow(response));
  }

  @override
  Future<void> withdrawRequest(String requestId, {String? note}) async {
    await _authenticatedPost('/v1/meetups/requests/$requestId/withdraw', {
      'note': note ?? '',
    });
  }

  @override
  Future<MeetupRequestModel> respondToRequest(
    String requestId, {
    required bool accept,
  }) async {
    final response = await _authenticatedPost(
      '/v1/meetups/requests/$requestId/respond',
      {'accept': accept},
    );
    return MeetupRequestModel.fromJson(_decodeOrThrow(response));
  }

  @override
  Future<void> registerDeviceToken(String fcmToken) async {
    await _authenticatedPost('/v1/meetups/device-token', {
      'fcm_token': fcmToken,
    });
  }

  @override
  Future<SafetyState> getSafetyState(String meetupId) async {
    final response = await _authenticatedGet('/v1/meetups/$meetupId/safety');
    return SafetyState.fromJson(_decodeOrThrow(response));
  }

  @override
  Future<SafetyState> acknowledgeSafetyChecklist(String meetupId) async {
    final response = await _authenticatedPost(
      '/v1/meetups/$meetupId/safety/checklist',
      const {},
    );
    return SafetyState.fromJson(_decodeOrThrow(response));
  }

  @override
  Future<SafetyState> setLiveLocationOptIn(String meetupId, bool optIn) async {
    final response = await _authenticatedPost(
      '/v1/meetups/$meetupId/safety/live-location',
      {'opt_in': optIn},
    );
    return SafetyState.fromJson(_decodeOrThrow(response));
  }

  @override
  Future<SafetyState> shareWithContacts(
    String meetupId,
    List<String> contactIds,
  ) async {
    final response = await _authenticatedPost(
      '/v1/meetups/$meetupId/safety/share',
      {'contact_ids': contactIds},
    );
    return SafetyState.fromJson(_decodeOrThrow(response));
  }

  @override
  Future<SafetyState> checkIn(String meetupId) async {
    final response = await _authenticatedPost(
      '/v1/meetups/$meetupId/safety/check-in',
      const {},
    );
    return SafetyState.fromJson(_decodeOrThrow(response));
  }

  @override
  Future<SafetyState> declineCheckIn(String meetupId, String reason) async {
    final response = await _authenticatedPost(
      '/v1/meetups/$meetupId/safety/decline',
      {'reason': reason},
    );
    return SafetyState.fromJson(_decodeOrThrow(response));
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
    await _authenticatedPost('/v1/meetups/$meetupId/feedback', {
      'happened': happened,
      'felt_safe': feltSafe,
      'profile_accurate': profileAccurate,
      'would_meet_again': wouldMeetAgain,
      'notes': notes,
    });
  }

  @override
  Future<List<RatableParticipant>> listRatableParticipants(
    String meetupId,
  ) async {
    final response = await _authenticatedGet(
      '/v1/meetups/$meetupId/ratings/ratable',
    );
    final decoded = _decodeOrThrow(response);
    return (decoded['participants'] as List<dynamic>)
        .map((e) => RatableParticipant.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<MeetupParticipants> listMeetupParticipants(String meetupId) async {
    final response = await _authenticatedGet(
      '/v1/meetups/$meetupId/participants',
    );
    return MeetupParticipants.fromJson(_decodeOrThrow(response));
  }

  @override
  Future<List<AppNotification>> listNotifications() async {
    final response = await _authenticatedGet('/v1/notifications');
    final decoded = _decodeOrThrow(response);
    return ((decoded['notifications'] as List<dynamic>?) ?? const [])
        .map((e) => AppNotification.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<RatableParticipants> listRatableParticipantsWithTraits(
    String meetupId,
  ) async {
    final response = await _authenticatedGet(
      '/v1/meetups/$meetupId/ratings/ratable',
    );
    return RatableParticipants.fromJson(_decodeOrThrow(response));
  }

  @override
  Future<void> submitMeetupReview(
    String meetupId, {
    required int overallScore,
    String? notes,
    required List<ReviewParticipantInput> participants,
  }) async {
    await _authenticatedPost('/v1/meetups/$meetupId/review', {
      'overall_score': overallScore,
      'notes': ?notes,
      'participants': participants.map((p) => p.toJson()).toList(),
    });
  }

  @override
  Future<MeetupReview> getMeetupReview(String meetupId) async {
    final response = await _authenticatedGet('/v1/meetups/$meetupId/review');
    return MeetupReview.fromJson(_decodeOrThrow(response));
  }

  @override
  Future<void> submitRating(
    String meetupId, {
    required String ratedUserId,
    required int score,
  }) async {
    await _authenticatedPost('/v1/meetups/$meetupId/ratings', {
      'rated_user_id': ratedUserId,
      'score': score,
    });
  }

  @override
  Future<Meetup> closeMeetup(String meetupId) async {
    final response = await _authenticatedPost(
      '/v1/meetups/$meetupId/close',
      const {},
    );
    return Meetup.fromJson(_decodeOrThrow(response));
  }

  @override
  Future<void> cancelMeetup(String meetupId, {required String reason}) async {
    await _authenticatedPost('/v1/meetups/$meetupId/cancel', {
      'reason': reason,
    });
  }

  Map<String, dynamic> _decodeOrThrow(http.Response response) {
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw _mapError(response);
  }

  MeetupException _mapError(http.Response response) {
    final message = _errorMessage(response.body);
    switch (response.statusCode) {
      case 400:
        return MeetupNetworkException(message);
      case 401:
        return MeetupSessionExpiredException(message);
      case 403:
        return MeetupForbiddenException(message);
      case 404:
        return MeetupNotFoundException(message);
      case 409:
        return MeetupConflictException(message);
      default:
        return MeetupNetworkException(message);
    }
  }

  String _errorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {
      // fall through to the generic message below
    }
    return 'Something went wrong. Please try again.';
  }

  Future<http.Response> _authenticatedPost(
    String path,
    Map<String, Object?> body,
  ) async {
    final headers = await _authHeaders();
    return _send(
      () => _httpClient.post(
        Uri.parse('$_baseUrl$path'),
        headers: headers,
        body: jsonEncode(body),
      ),
    );
  }

  Future<http.Response> _authenticatedGet(
    String path, {
    Map<String, String>? query,
  }) async {
    final headers = await _authHeaders();
    final uri = Uri.parse(
      '$_baseUrl$path',
    ).replace(queryParameters: query?.isEmpty ?? true ? null : query);
    return _send(() => _httpClient.get(uri, headers: headers));
  }

  /// Turns a failure to REACH the server into a typed
  /// [MeetupOfflineException].
  ///
  /// Previously these escaped as a raw `SocketException` or
  /// `http.ClientException`, which is neither a [MeetupException] nor
  /// anything a caller could match on — so every screen either swallowed it
  /// into a generic message or let it surface as an unhandled error. A
  /// connectivity failure is the one error the user can actually do
  /// something about, so it is worth naming.
  ///
  /// Deliberately narrow: only transport-level failures are caught here. A
  /// response that arrives and happens to be a 500 is not a connection
  /// problem and is still mapped by [_mapError].
  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request();
    } on SocketException catch (error) {
      throw MeetupOfflineException(_offlineMessage(error));
    } on http.ClientException catch (error) {
      throw MeetupOfflineException(_offlineMessage(error));
    } on TimeoutException catch (error) {
      throw MeetupOfflineException(_offlineMessage(error));
    }
  }

  /// The exception's own text is deliberately discarded — it carries host
  /// names, ports and errno strings that mean nothing to a user.
  String _offlineMessage(Object _) =>
      'No connection. Check your network and try again.';

  Future<Map<String, String>> _authHeaders() async {
    final token = await _getAccessToken();
    // No token means the session is gone from storage entirely — not
    // merely stale, which getValidSession() would have refreshed before
    // returning. Sending the request without an Authorization header buys
    // a guaranteed 401 that no refresh can repair (there is no refresh
    // token left to send), and a provider that retries would keep doing it
    // forever. Fail here with the same exception a real 401 maps to, so
    // AppShell's session-expired listener lands the user on LandingPage.
    if (token == null) {
      throw const MeetupSessionExpiredException(
        'Your session has expired. Please sign in again.',
      );
    }
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }
}
