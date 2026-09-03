import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:professional_connections_platform/core/config/app_config.dart';
import 'package:professional_connections_platform/core/services/subscription_service.dart';

/// Real [SubscriptionService] wired to the gateway's `/v1/billing/*` REST
/// contract (ADR-031, Slice B) plus a direct `in_app_purchase` call for
/// [availableProducts] (see the interface doc comment for why that one
/// method doesn't go through the backend). Same getAccessToken-via-
/// TokenRefresher wiring as [HttpMeetupService] — holds no session state of
/// its own.
class HttpSubscriptionService implements SubscriptionService {
  HttpSubscriptionService({
    http.Client? httpClient,
    String? baseUrl,
    Future<String?> Function()? getAccessToken,
    InAppPurchase? inAppPurchase,
  }) : _httpClient = httpClient ?? http.Client(),
       _baseUrl = baseUrl ?? AppConfig.gatewayBaseUrl,
       _getAccessToken = getAccessToken ?? (() async => null),
       _injectedInAppPurchase = inAppPurchase;

  final http.Client _httpClient;
  final String _baseUrl;
  final Future<String?> Function() _getAccessToken;
  final InAppPurchase? _injectedInAppPurchase;

  // Deliberately lazy, not resolved in the constructor — InAppPurchase
  // .instance registers a real platform channel on first access (on
  // Android, it stands up a BillingClient), which throws under `flutter
  // test`'s binding if this service is constructed just to call
  // currentStatus()/verifyPurchase() and never touches purchases at all.
  InAppPurchase get _inAppPurchase =>
      _injectedInAppPurchase ?? InAppPurchase.instance;

  @override
  Future<SubscriptionStatus> currentStatus() async {
    final response = await _authenticatedGet('/v1/billing/subscription');
    return SubscriptionStatus.fromJson(_decodeOrThrow(response));
  }

  @override
  Future<List<ProductDetails>> availableProducts(
    List<String> productIds,
  ) async {
    final response = await _inAppPurchase.queryProductDetails(
      productIds.toSet(),
    );
    if (response.error != null) {
      throw SubscriptionException(
        'Could not load subscription options. Please try again.',
      );
    }
    return response.productDetails;
  }

  @override
  Future<SubscriptionStatus> verifyPurchase({
    required String platform,
    required String receiptOrToken,
    required String productId,
  }) async {
    final response = await _authenticatedPost('/v1/billing/purchases/verify', {
      'platform': platform,
      'receipt_or_token': receiptOrToken,
      'product_id': productId,
    });
    return SubscriptionStatus.fromJson(_decodeOrThrow(response));
  }

  @override
  Future<void> restorePurchases() => _inAppPurchase.restorePurchases();

  Map<String, dynamic> _decodeOrThrow(http.Response response) {
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw SubscriptionException(_errorMessage(response.body));
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
    return _httpClient.post(
      Uri.parse('$_baseUrl$path'),
      headers: headers,
      body: jsonEncode(body),
    );
  }

  Future<http.Response> _authenticatedGet(String path) async {
    final headers = await _authHeaders();
    return _httpClient.get(Uri.parse('$_baseUrl$path'), headers: headers);
  }

  Future<Map<String, String>> _authHeaders() async {
    final token = await _getAccessToken();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }
}
