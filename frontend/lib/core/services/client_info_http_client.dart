import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:professional_connections_platform/core/analytics/analytics.dart';
import 'package:professional_connections_platform/core/config/app_version.dart';

/// Stamps every request with `X-App-Version` and `X-Platform` (plan 29 §2).
///
/// The ONE place these headers are set: every HTTP service wraps its
/// client in this, whatever else it wraps it in, so a new service cannot
/// forget them. The server uses them to keep builds without the credits
/// screens from creating meetups they cannot price (426), and to evaluate
/// version-gated flags.
class ClientInfoHttpClient extends http.BaseClient {
  ClientInfoHttpClient(this._inner, {String? platform})
    : _platform = platform ?? currentPlatform();

  final http.Client _inner;
  final String _platform;

  /// `ios`, `android` or `web`, the values the server accepts.
  static String currentPlatform() {
    if (kIsWeb) return 'web';
    return defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.headers['X-App-Version'] = AppVersion.header;
    request.headers['X-Platform'] = _platform;
    if (!ApiActivity.active) return _inner.send(request);

    // Plan 29E friction signals, from the one client every service shares:
    // an error status is `api_error`; no connection is `api_error`
    // (network); no answer within [ApiActivity.slowAfter] is
    // `request_timeout`, whichever layer above gives up on it first. Route
    // templates only, never the URL itself.
    var timedOut = false;
    final watch = Timer(ApiActivity.slowAfter, () {
      timedOut = true;
      ApiActivity.failed(request.method, request.url, timeout: true);
    });
    try {
      final response = await _inner.send(request);
      watch.cancel();
      if (!timedOut) {
        ApiActivity.status(request.method, request.url, response.statusCode);
      }
      return response;
    } on SocketException {
      watch.cancel();
      if (!timedOut) {
        ApiActivity.failed(request.method, request.url, timeout: false);
      }
      rethrow;
    } on http.ClientException {
      watch.cancel();
      if (!timedOut) {
        ApiActivity.failed(request.method, request.url, timeout: false);
      }
      rethrow;
    } catch (_) {
      watch.cancel();
      rethrow;
    }
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
