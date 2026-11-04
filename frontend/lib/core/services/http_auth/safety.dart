part of '../http_auth_service.dart';

/// Trusted contacts, SOS and the last-known location.
mixin _SafetyMethods on _HttpAuthBase {
  /// Per-attempt deadline for the SOS trigger — shorter than the
  /// client's own, because somebody is watching a spinner during an
  /// emergency. See triggerSos for why there is exactly one retry.
  static const Duration _sosAttemptTimeout = Duration(seconds: 10);

  @override
  Future<TrustedContact> addTrustedContact({
    required String name,
    required String phoneNumber,
  }) async {
    final response = await _authenticatedPost('/v1/sos/contacts', {
      'name': name,
      'phone_number': phoneNumber,
    });
    if (response.statusCode == 200) {
      return TrustedContact.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    }
    throw _mapVerificationError(response, on400: AuthNetworkException.new);
  }

  @override
  Future<TrustedContact> updateTrustedContact(
    String contactId, {
    required String name,
    required String phoneNumber,
  }) async {
    final headers = await _authHeaders();
    final response = await _httpClient.put(
      Uri.parse('$_baseUrl/v1/sos/contacts/$contactId'),
      headers: headers,
      body: jsonEncode({'name': name, 'phone_number': phoneNumber}),
    );
    if (response.statusCode == 200) {
      return TrustedContact.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    }
    if (response.statusCode == 403) {
      throw ForbiddenActionException(_errorMessage(response.body));
    }
    throw _mapVerificationError(response, on400: AuthNetworkException.new);
  }

  @override
  Future<List<TrustedContact>> listTrustedContacts() async {
    final headers = await _authHeaders();
    final response = await _httpClient.get(
      Uri.parse('$_baseUrl/v1/sos/contacts'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final contacts = decoded['contacts'] as List<dynamic>? ?? [];
      return contacts
          .map((c) => TrustedContact.fromJson(c as Map<String, dynamic>))
          .toList();
    }
    throw _mapVerificationError(response, on400: AuthNetworkException.new);
  }

  @override
  Future<void> removeTrustedContact(String contactId) async {
    final headers = await _authHeaders();
    final response = await _httpClient.delete(
      Uri.parse('$_baseUrl/v1/sos/contacts/$contactId'),
      headers: headers,
    );
    if (response.statusCode == 204) return;
    if (response.statusCode == 403) {
      throw ForbiddenActionException(_errorMessage(response.body));
    }
    throw _mapVerificationError(response, on400: AuthNetworkException.new);
  }

  @override
  Future<int> triggerSos({
    required String contextMessage,
    double? latitude,
    double? longitude,
    DateTime? capturedAt,
    String? source,
    String? clientRequestId,
  }) async {
    // # SHORTER DEADLINE, AND ONE RETRY (tracker #78)
    //
    // Every other call here gets the client's 15 s. This one gets 10 and
    // then tries once more, because the situation is different: somebody
    // has pressed an emergency button and is watching. Fifteen seconds of
    // nothing, then a failure, is worse than ten seconds, a silent
    // retry, and an answer at twenty — the retry costs nothing when the
    // first attempt was a dropped packet, which on a phone is the common
    // case.
    //
    // Exactly one retry, and it carries the SAME client_request_id as the
    // first attempt. When the first attempt did reach the server and was
    // still texting contacts as it timed out, the server sees the id,
    // sends nothing, and answers with that attempt's outcome — so a slow
    // network can no longer alert everyone twice. The user's own Retry on
    // the failure screen passes the sheet's id back in, for the same reason.
    //
    // A coordinate pair is sent only if BOTH are present. Half a
    // location is not a location, and the fields are omitted entirely
    // rather than sent as null, so the server reads absence rather than
    // having to interpret it.
    final body = <String, dynamic>{
      'context_message': contextMessage,
      'client_request_id': clientRequestId ?? newSosRequestId(),
    };
    if (latitude != null && longitude != null) {
      body['latitude'] = latitude;
      body['longitude'] = longitude;
      if (capturedAt != null) {
        body['captured_at'] = capturedAt.toUtc().toIso8601String();
      }
      if (source != null) body['source'] = source;
    }

    Future<http.Response> attempt() =>
        _authenticatedPost('/v1/sos/trigger', body).timeout(_sosAttemptTimeout);

    http.Response response;
    try {
      response = await attempt();
    } on TimeoutException {
      response = await _retrySosAfterTimeout(attempt);
    } on AuthNetworkException {
      response = await _retrySosAfterTimeout(attempt);
    }

    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      return decoded['contacts_notified'] as int? ?? 0;
    }
    throw _mapVerificationError(response, on400: AuthNetworkException.new);
  }

  /// The second and last SOS attempt. Split out so the two failure modes
  /// that reach it — a timeout, and the deadline client's own network
  /// error — share one definition of "try once more, then give up with
  /// something the screen can act on".
  Future<http.Response> _retrySosAfterTimeout(
    Future<http.Response> Function() attempt,
  ) async {
    try {
      return await attempt();
    } on TimeoutException {
      throw const AuthNetworkException(
        'Could not send the alert. Check your connection and try again, '
        'or call emergency services.',
      );
    }
  }

  @override
  Future<void> updateLastKnownLocation({
    required double latitude,
    required double longitude,
  }) async {
    final response = await _authenticatedPost('/v1/users/me/location', {
      'latitude': latitude,
      'longitude': longitude,
    });
    if (response.statusCode == 204) return;
    throw _mapVerificationError(response, on400: AuthNetworkException.new);
  }
}
