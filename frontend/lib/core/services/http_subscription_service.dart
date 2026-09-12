import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:professional_connections_platform/core/config/app_config.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
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

    // 503 means the billing module does not exist yet - it is Phase 3, and
    // every billing route answers 503 by design until it lands (see the
    // backend's handlers/unavailable.go). That is NOT a transient failure
    // to retry: it is a permanent, expected answer for now.
    //
    // Throwing here was expensive. subscriptionStatusProvider is watched by
    // ProfilePage, a keep-alive tab, and Riverpod 3 auto-retries a failed
    // provider with backoff - so the permanent 503 became an endless retry
    // loop at roughly 8-10 requests/minute per device, for as long as the
    // app stayed open. In the deployed service's logs it was the single
    // busiest endpoint, with a 100% failure rate, and a request every few
    // seconds is also enough to stop Cloud Run ever scaling to zero.
    //
    // free/none is the honest answer, not a fudge: it is the same state the
    // backend synthesizes for someone who has never purchased anything, and
    // "no billing module" and "no subscription" entitle the user to exactly
    // the same thing. isEntitled stays false either way, so nothing is
    // unlocked by this.
    if (response.statusCode == 503) {
      return const SubscriptionStatus(
        tier: SubscriptionTier.free,
        status: SubscriptionLifecycleStatus.none,
      );
    }

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
    // No token means the session is gone from storage entirely — not
    // merely stale, which getValidSession() would have refreshed before
    // returning. Sending the request without an Authorization header buys
    // a guaranteed 401 that no refresh can repair (there is no refresh
    // token left to send), and a provider that retries would keep doing it
    // forever. Fail here with the same exception a real 401 maps to, so
    // AppShell's session-expired listener lands the user on LandingPage.
    if (token == null) {
      throw const SessionExpiredException(
        'Your session has expired. Please sign in again.',
      );
    }
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }
}
