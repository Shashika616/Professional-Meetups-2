import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:professional_connections_platform/core/config/app_config.dart';
import 'package:professional_connections_platform/core/config/update_required.dart';
import 'package:professional_connections_platform/core/models/credits.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/services/client_info_http_client.dart';
import 'package:professional_connections_platform/core/services/credit_service.dart';
import 'package:professional_connections_platform/core/services/deadline_http_client.dart';

/// Real [CreditService] over the gateway's `/v1/billing/*` routes.
///
/// Every request goes through [DeadlineHttpClient] (a hard deadline, one
/// offline error) and [ClientInfoHttpClient] (the version headers),
/// including one a test injects, so the production path is the one under
/// test.
class HttpCreditService implements CreditService {
  HttpCreditService({
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

  @override
  Future<Wallet> wallet() async {
    final r = await _get('/v1/billing/wallet');
    if (r.statusCode == 503) return Wallet.empty;
    return Wallet.fromJson(_decode(r));
  }

  @override
  Future<LedgerPage> ledger({String? cursor}) async {
    final r = await _get(
      '/v1/billing/ledger',
      query: {if (cursor != null && cursor.isNotEmpty) 'cursor': cursor},
    );
    if (r.statusCode == 503) return LedgerPage.empty;
    return LedgerPage.fromJson(_decode(r));
  }

  @override
  Future<CreditQuote> quote({
    required int capacity,
    required DateTime windowStart,
  }) async {
    final r = await _post('/v1/billing/quote', {
      'capacity': capacity,
      'window_start_unix_seconds': windowStart.millisecondsSinceEpoch ~/ 1000,
    });
    return CreditQuote.fromJson(_decode(r));
  }

  @override
  Future<Entitlements> entitlements() async {
    final r = await _get('/v1/billing/entitlements');
    if (r.statusCode == 503) return Entitlements.fallback;
    return Entitlements.fromJson(_decode(r));
  }

  @override
  Future<Catalog> catalog() async {
    // Signed in or not: the catalog is filtered for the caller when there
    // is one, and plans can still show to everyone once the flag is on.
    final r = await _get('/v1/billing/catalog', optionalAuth: true);
    if (r.statusCode == 503) return Catalog.empty;
    return Catalog.fromJson(_decode(r));
  }

  @override
  Future<PurchaseGrant> verifyPurchase({
    required String platform,
    required String productId,
    required String token,
  }) async {
    final r = await _post('/v1/billing/purchases/verify', {
      'platform': platform,
      'product_id': productId,
      'token': token,
    });
    return PurchaseGrant.fromJson(_decode(r));
  }

  Map<String, dynamic> _decode(http.Response r) {
    if (r.statusCode == 200) {
      try {
        return jsonDecode(r.body) as Map<String, dynamic>;
      } catch (_) {
        throw const CreditServerException();
      }
    }
    final message = _message(r.body);
    switch (r.statusCode) {
      case 401:
        throw const CreditSessionExpiredException();
      case 426:
        UpdateRequired.signalled.value = true;
        throw const CreditUpdateRequiredException();
      case 503:
        throw const CreditUnavailableException();
      case 400 || 403 || 409 || 402:
        throw CreditRejectedException(
          message ?? 'This could not be done. Please try again.',
          statusCode: r.statusCode,
        );
      default:
        throw const CreditServerException();
    }
  }

  String? _message(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {
      // not JSON
    }
    return null;
  }

  Future<http.Response> _get(
    String path, {
    Map<String, String>? query,
    bool optionalAuth = false,
  }) async {
    final headers = await _headers(optional: optionalAuth);
    final uri = Uri.parse(
      '$_baseUrl$path',
    ).replace(queryParameters: (query == null || query.isEmpty) ? null : query);
    return _send(() => _httpClient.get(uri, headers: headers));
  }

  Future<http.Response> _post(String path, Map<String, Object?> body) async {
    final headers = await _headers();
    return _send(
      () => _httpClient.post(
        Uri.parse('$_baseUrl$path'),
        headers: headers,
        body: jsonEncode(body),
      ),
    );
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request();
    } on AuthNetworkException catch (e) {
      throw CreditOfflineException(e.message);
    }
  }

  Future<Map<String, String>> _headers({bool optional = false}) async {
    final token = await _getAccessToken();
    // No token at all means the session is gone (a stale one would have
    // been refreshed): fail like a 401 rather than send a request that can
    // only be refused.
    if (token == null && !optional) throw const CreditSessionExpiredException();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }
}
