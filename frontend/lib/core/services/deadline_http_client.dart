import 'dart:async';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

import 'package:professional_connections_platform/core/services/auth_service.dart';

/// An [http.Client] that refuses to wait forever and reports a failure to
/// reach the server as one typed error (tracker #78, review findings
/// N-D1/N-D3).
///
/// # WHY THIS IS A CLIENT AND NOT A HELPER FUNCTION
///
/// The auth service makes seventeen requests. Before this, NONE of them
/// had a deadline: `http.Client.post` with no timeout waits as long as
/// the platform's socket does, which on a phone that has drifted out of
/// coverage is minutes. The meetup client already had 20 s; the auth
/// client — the one that refreshes sessions and triggers SOS — had
/// nothing.
///
/// Wrapping each call site would have meant seventeen edits and an
/// eighteenth request written next month without one. Every convenience
/// method on [http.BaseClient] funnels through [send], so overriding that
/// one method puts the deadline somewhere it cannot be forgotten.
///
/// # WHAT IT MAPS
///
/// [SocketException] (no route, DNS failure, connection refused),
/// [http.ClientException] (connection closed mid-response) and
/// [TimeoutException] all mean the same thing to a caller: the request
/// did not reach the server, or its answer did not come back. They are
/// three types from three layers describing one situation, and the UI has
/// one thing to say about it. Collapsing them here is what lets a screen
/// `catch (AuthNetworkException)` and be sure it has covered the lot.
///
/// Anything else is left alone — an HTTP error status is a real answer
/// and belongs to whoever reads the response.
class DeadlineHttpClient extends http.BaseClient {
  DeadlineHttpClient(this._inner, {this.timeout = defaultTimeout});

  /// 15 s. Long enough for a slow mobile network to answer, short enough
  /// that a person watching a spinner learns something.
  static const Duration defaultTimeout = Duration(seconds: 15);

  final http.Client _inner;
  final Duration timeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    try {
      return await _inner.send(request).timeout(timeout);
    } on TimeoutException {
      throw const AuthNetworkException(
        'The server did not respond. Check your connection and try again.',
      );
    } on SocketException {
      throw const AuthNetworkException(
        'Could not reach the server. Check your connection and try again.',
      );
    } on http.ClientException {
      throw const AuthNetworkException(
        'The connection was interrupted. Please try again.',
      );
    }
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
