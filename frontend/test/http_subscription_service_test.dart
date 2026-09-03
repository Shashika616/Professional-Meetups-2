import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:professional_connections_platform/core/services/http_subscription_service.dart';
import 'package:professional_connections_platform/core/services/subscription_service.dart';

const _baseUrl = 'http://localhost:8080';

HttpSubscriptionService _serviceWith(http.Client client) =>
    HttpSubscriptionService(httpClient: client, baseUrl: _baseUrl);

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
}
