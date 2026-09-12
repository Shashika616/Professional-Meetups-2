import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/services/http_subscription_service.dart';
import 'package:professional_connections_platform/core/services/subscription_service.dart';

const _baseUrl = 'http://localhost:8080';

HttpSubscriptionService _serviceWith(http.Client client) =>
    HttpSubscriptionService(
      httpClient: client,
      baseUrl: _baseUrl,
      // Authenticated calls now fail fast without one, so every test that
      // exercises a response body needs a session present.
      getAccessToken: () async => 'token',
    );

void main() {
  group('currentStatus', () {
    test('200 parses into a SubscriptionStatus', () async {
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.toString(), '$_baseUrl/v1/billing/subscription');
        return http.Response(
          jsonEncode({
            'tier': 'premium',
            'status': 'active',
            'platform': 'ios',
            'current_period_end_unix_seconds': 1893456000,
            'auto_renew_status': true,
          }),
          200,
        );
      });

      final status = await _serviceWith(client).currentStatus();

      expect(status.tier, SubscriptionTier.premium);
      expect(status.status, SubscriptionLifecycleStatus.active);
      expect(status.isEntitled, isTrue);
      expect(status.autoRenewStatus, isTrue);
    });

    test('no subscription row synthesizes free/none', () async {
      final client = MockClient(
        (request) async =>
            http.Response(jsonEncode({'tier': 'free', 'status': 'none'}), 200),
      );

      final status = await _serviceWith(client).currentStatus();

      expect(status.tier, SubscriptionTier.free);
      expect(status.status, SubscriptionLifecycleStatus.none);
      expect(status.isEntitled, isFalse);
    });

    // The billing module is Phase 3 and not built yet: every billing route
    // answers 503 ("billing is not configured") by design - see the
    // backend's handlers/unavailable.go.
    //
    // Throwing on that was a real, measurable cost. subscriptionStatusProvider
    // is watched by ProfilePage, which is a keep-alive tab, and Riverpod 3
    // auto-retries a failed provider with backoff - so a permanent 503
    // became an endless retry loop: ~8-10 requests/minute for as long as the
    // app was open, on every device. Confirmed in the deployed service's own
    // logs, where /v1/billing/subscription was the single busiest endpoint
    // and 100% of its responses were 503. A request every few seconds also
    // keeps the Cloud Run instance from ever scaling to zero.
    //
    // 503 here does not mean "try again" - it means "this module does not
    // exist yet", which is exactly the free/none state the domain already
    // models for a user who has never purchased anything.
    test(
      '503 (billing not configured) resolves to free/none, never throws',
      () async {
        var calls = 0;
        final client = MockClient((request) async {
          calls++;
          return http.Response(
            jsonEncode({'error': 'billing is not configured'}),
            503,
          );
        });

        final status = await _serviceWith(client).currentStatus();

        expect(status.tier, SubscriptionTier.free);
        expect(status.status, SubscriptionLifecycleStatus.none);
        expect(status.isEntitled, isFalse);
        expect(calls, 1, reason: 'one call, and nothing to retry');
      },
    );

    test(
      'non-200 throws SubscriptionException with the server message',
      () async {
        final client = MockClient(
          (request) async =>
              http.Response(jsonEncode({'error': 'unauthenticated'}), 401),
        );

        expect(
          () => _serviceWith(client).currentStatus(),
          throwsA(
            isA<SubscriptionException>().having(
              (e) => e.message,
              'message',
              'unauthenticated',
            ),
          ),
        );
      },
    );
  });

  group('verifyPurchase', () {
    test('sends platform/receipt/productId and parses the response', () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), '$_baseUrl/v1/billing/purchases/verify');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['platform'], 'ios');
        expect(body['receipt_or_token'], 'jws-token');
        expect(body['product_id'], 'premium_monthly');

        return http.Response(
          jsonEncode({'tier': 'premium', 'status': 'active'}),
          200,
        );
      });

      final status = await _serviceWith(client).verifyPurchase(
        platform: 'ios',
        receiptOrToken: 'jws-token',
        productId: 'premium_monthly',
      );

      expect(status.isEntitled, isTrue);
    });

    test(
      'server rejection throws SubscriptionException, does not activate',
      () async {
        final client = MockClient(
          (request) async => http.Response(
            jsonEncode({'error': 'purchase could not be verified'}),
            400,
          ),
        );

        expect(
          () => _serviceWith(client).verifyPurchase(
            platform: 'android',
            receiptOrToken: 'bad-token',
            productId: 'premium_monthly',
          ),
          throwsA(isA<SubscriptionException>()),
        );
      },
    );
  });

  group('missing session', () {
    test('currentStatus fails fast rather than sending an unauthenticated '
        'request that a provider would retry forever', () async {
      var requestsSent = 0;
      final client = MockClient((request) async {
        requestsSent++;
        return http.Response('{}', 200);
      });
      final service = HttpSubscriptionService(
        httpClient: client,
        baseUrl: _baseUrl,
        getAccessToken: () async => null,
      );

      await expectLater(
        service.currentStatus(),
        throwsA(isA<SessionExpiredException>()),
      );
      expect(requestsSent, 0);
    });
  });
}
