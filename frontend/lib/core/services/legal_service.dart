import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:professional_connections_platform/core/config/app_config.dart';
import 'package:professional_connections_platform/core/services/client_info_http_client.dart';
import 'package:professional_connections_platform/core/services/deadline_http_client.dart';

/// The current terms and privacy policy, as Markdown.
class LegalDocuments {
  const LegalDocuments({
    required this.version,
    required this.terms,
    required this.privacy,
  });

  final String version;
  final String terms;
  final String privacy;
}

class LegalException implements Exception {
  const LegalException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract interface class LegalService {
  /// Throws [LegalException] when they cannot be loaded.
  Future<LegalDocuments> documents();

  /// Whether the signed-in user agreed to the current version.
  Future<bool> hasAccepted();

  /// Records agreement to [version]. Throws [LegalException] if the server
  /// refuses, including when the documents changed in the meantime.
  Future<void> accept(String version);
}

class HttpLegalService implements LegalService {
  HttpLegalService({
    http.Client? httpClient,
    String? baseUrl,
    Future<String?> Function()? getAccessToken,
  }) : _httpClient = DeadlineHttpClient(
         ClientInfoHttpClient(httpClient ?? http.Client()),
       ),
       _baseUrl = baseUrl ?? AppConfig.gatewayBaseUrl,
       _getAccessToken = getAccessToken ?? (() async => null);

  final http.Client _httpClient;
  final String _baseUrl;
  final Future<String?> Function() _getAccessToken;

  static const _unavailable = LegalException(
    'We couldn’t load this. Check your connection and try again.',
  );

  Future<Map<String, String>> _headers() async {
    final token = await _getAccessToken();
    return {
      'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  @override
  Future<LegalDocuments> documents() async {
    try {
      final response = await _httpClient.get(Uri.parse('$_baseUrl/v1/legal'));
      if (response.statusCode != 200) throw _unavailable;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return LegalDocuments(
        version: body['version'] as String? ?? '',
        terms: body['terms'] as String? ?? '',
        privacy: body['privacy'] as String? ?? '',
      );
    } on LegalException {
      rethrow;
    } catch (_) {
      throw _unavailable;
    }
  }

  @override
  Future<bool> hasAccepted() async {
    try {
      final response = await _httpClient.get(
        Uri.parse('$_baseUrl/v1/legal/acceptance'),
        headers: await _headers(),
      );
      if (response.statusCode != 200) throw _unavailable;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return body['accepted'] as bool? ?? false;
    } on LegalException {
      rethrow;
    } catch (_) {
      throw _unavailable;
    }
  }

  @override
  Future<void> accept(String version) async {
    final http.Response response;
    try {
      response = await _httpClient.post(
        Uri.parse('$_baseUrl/v1/legal/acceptance'),
        headers: await _headers(),
        body: jsonEncode({'version': version}),
      );
    } catch (_) {
      throw _unavailable;
    }
    if (response.statusCode == 204) return;
    if (response.statusCode == 409) {
      throw const LegalException(
        'These terms have changed. Please review them again.',
      );
    }
    throw _unavailable;
  }
}
