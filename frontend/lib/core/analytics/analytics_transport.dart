import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'package:professional_connections_platform/core/config/app_config.dart';
import 'package:professional_connections_platform/core/services/client_info_http_client.dart';
import 'package:professional_connections_platform/core/services/deadline_http_client.dart';

/// What happened to one batch.
sealed class SendResult {
  const SendResult();
}

/// The server took it (202).
class Sent extends SendResult {
  const Sent();
}

/// Try again later: offline, a 5xx, or 429 ([after] from `Retry-After`).
class RetryLater extends SendResult {
  const RetryLater({this.after});
  final Duration? after;
}

/// The server refused it for good (400, 413): resending cannot help.
class Refused extends SendResult {
  const Refused();
}

/// Sends batches and the consent choice.
abstract interface class AnalyticsTransport {
  Future<SendResult> send(Map<String, Object?> batch);

  /// `PUT /v1/analytics/consent`. Best effort; false when it did not reach
  /// the server or there is no session.
  Future<bool> setConsent({required bool optedOut});
}

/// The real transport: gzip JSON to the gateway, the access token when
/// there is one (anonymous otherwise), through the same deadline and
/// client-info wrappers as every other service.
class HttpAnalyticsTransport implements AnalyticsTransport {
  HttpAnalyticsTransport({
    http.Client? httpClient,
    String? baseUrl,
    Future<String?> Function()? getAccessToken,
  }) : _http = DeadlineHttpClient(
         ClientInfoHttpClient(httpClient ?? http.Client()),
       ),
       _baseUrl = baseUrl ?? AppConfig.gatewayBaseUrl,
       _getAccessToken = getAccessToken ?? (() async => null);

  final http.Client _http;
  final String _baseUrl;
  final Future<String?> Function() _getAccessToken;

  Future<Map<String, String>> _headers() async {
    final headers = {'Content-Type': 'application/json'};
    try {
      final token = await _getAccessToken();
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
    } catch (_) {
      // No session (or a dead one): send anonymously.
    }
    return headers;
  }

  @override
  Future<SendResult> send(Map<String, Object?> batch) async {
    try {
      final headers = await _headers();
      final json = utf8.encode(jsonEncode(batch));
      List<int> body = json;
      if (!kIsWeb) {
        body = gzip.encode(json);
        headers['Content-Encoding'] = 'gzip';
      }
      final response = await _http.post(
        Uri.parse('$_baseUrl/v1/analytics/events'),
        headers: headers,
        body: body,
      );
      final status = response.statusCode;
      if (status == 202 || status == 200) return const Sent();
      if (status == 429) {
        final seconds = int.tryParse(response.headers['retry-after'] ?? '');
        return RetryLater(
          after: seconds == null ? null : Duration(seconds: seconds),
        );
      }
      if (status >= 500) return const RetryLater();
      return const Refused();
    } catch (_) {
      // Offline, no answer in time: keep the events and try later.
      return const RetryLater();
    }
  }

  @override
  Future<bool> setConsent({required bool optedOut}) async {
    try {
      final headers = await _headers();
      if (!headers.containsKey('Authorization')) return false;
      final response = await _http.put(
        Uri.parse('$_baseUrl/v1/analytics/consent'),
        headers: headers,
        body: jsonEncode({'opted_out': optedOut}),
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
