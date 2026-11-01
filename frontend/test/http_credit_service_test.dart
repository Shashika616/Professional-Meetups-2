import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:professional_connections_platform/core/models/credits.dart';
import 'package:professional_connections_platform/core/services/app_config_service.dart';
import 'package:professional_connections_platform/core/services/credit_service.dart';
import 'package:professional_connections_platform/core/services/http_credit_service.dart';

const _base = 'http://localhost:8080';

HttpCreditService _service(MockClient client, {String? token = 'tok'}) =>
    HttpCreditService(
      httpClient: client,
      baseUrl: _base,
      getAccessToken: () async => token,
    );

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

void main() {
  test('wallet parses, with the version headers and the token', () async {
    late http.Request seen;
    final w = await _service(
      MockClient((r) async {
        seen = r;
        return _json({
          'balance': 60,
          'held': 10,
          'available': 50,
          'debt': 0,
          'expiring_soon': [
            {
              'kind': 'welcome',
              'remaining': 54,
              'next_decay_at_unix_seconds': 1762387200,
              'next_decay_credits': 6,
            },
          ],
        });
      }),
    ).wallet();
    expect(seen.url.toString(), '$_base/v1/billing/wallet');
    expect(seen.headers['Authorization'], 'Bearer tok');
    expect(seen.headers['X-App-Version'], isNotEmpty);
    expect(seen.headers['X-Platform'], isNotEmpty);
    expect(w.available, 50);
    expect(w.expiringSoon.single.nextDecayCredits, 6);
  });

  test(
    '503 is a safe default for the reads, so no provider retries in a loop',
    () async {
      final s = _service(
        MockClient((_) async => _json({'error': 'down'}, 503)),
      );
      expect((await s.wallet()).available, 0);
      expect((await s.ledger()).entries, isEmpty);
      expect((await s.entitlements()).limits.maxAdvanceDays, 14);
      expect((await s.catalog()).plansVisible, isFalse);
      // A price and a grant have no safe default.
      expect(
        () => s.quote(capacity: 4, windowStart: DateTime(2030)),
        throwsA(isA<CreditUnavailableException>()),
      );
      expect(
        () => s.verifyPurchase(
          platform: 'ios',
          productId: 'credits_50',
          token: 't',
        ),
        throwsA(isA<CreditUnavailableException>()),
      );
    },
  );

  test('the quote sends what the user chose and nothing about money', () async {
    late Map<String, dynamic> body;
    final q =
        await _service(
          MockClient((r) async {
            body = jsonDecode(r.body) as Map<String, dynamic>;
            return _json({
              'cost': 17,
              'would_cost': 17,
              'price_version': 3,
              'covered_by_plan': false,
              'balance_available': 12,
              'limits': {'max_capacity': 20, 'max_advance_days': 14},
            });
          }),
        ).quote(
          capacity: 6,
          windowStart: DateTime.fromMillisecondsSinceEpoch(1761400000 * 1000),
        );
    expect(body, {'capacity': 6, 'window_start_unix_seconds': 1761400000});
    expect(q.cost, 17);
    expect(q.priceVersion, 3);
    expect(q.affordable, isFalse);
  });

  test('the ledger pages by cursor', () async {
    final cursors = <String?>[];
    final s = _service(
      MockClient((r) async {
        cursors.add(r.url.queryParameters['cursor']);
        return _json({
          'entries': [
            {
              'id': 9,
              'delta': 60,
              'reason': 'grant',
              'ref_type': 'welcome',
              'balance_after': 60,
              'created_at_unix_seconds': 1761300000,
            },
          ],
          'next_cursor': r.url.queryParameters['cursor'] == null ? 'OQ' : '',
        });
      }),
    );
    final first = await s.ledger();
    expect(first.entries.single.label, 'Welcome credits');
    expect(first.nextCursor, 'OQ');
    final second = await s.ledger(cursor: first.nextCursor);
    expect(second.nextCursor, isNull);
    expect(cursors, [null, 'OQ']);
  });

  test('the catalog is asked for signed in or not', () async {
    late http.Request seen;
    final c = await _service(
      MockClient((r) async {
        seen = r;
        return _json({
          'catalog_version': 2,
          'credit_packs': [
            {
              'product_id': 'credits_120',
              'credits': 120,
              'bonus': 20,
              'badge': 'popular',
              'sort': 2,
            },
          ],
          'plans_visible': false,
          'plans': [],
        });
      }),
      token: null,
    ).catalog();
    expect(seen.headers.containsKey('Authorization'), isFalse);
    expect(c.creditPacks.single.badgeLabel, 'Popular');
    expect(c.version, 2);
  });

  test('verify sends exactly platform, product and token', () async {
    late Map<String, dynamic> body;
    final g =
        await _service(
          MockClient((r) async {
            body = jsonDecode(r.body) as Map<String, dynamic>;
            return _json({
              'kind': 'consumable',
              'product_id': 'credits_50',
              'credits_granted': 50,
              'already_processed': false,
              'wallet': {
                'balance': 110,
                'held': 0,
                'available': 110,
                'debt': 0,
                'expiring_soon': [],
              },
              'subscription': {
                'status': 'none',
                'auto_renew': false,
                'entitled': false,
              },
            });
          }),
        ).verifyPurchase(
          platform: 'android',
          productId: 'credits_50',
          token: 'purchase-token',
        );
    expect(body, {
      'platform': 'android',
      'product_id': 'credits_50',
      'token': 'purchase-token',
    });
    expect(g.creditsGranted, 50);
    expect(g.wallet.available, 110);
  });

  test('errors map to typed exceptions with the server\'s sentence', () async {
    Future<Object?> fail(int status) async {
      try {
        await _service(
          MockClient(
            (_) async => _json({
              'error': 'This purchase belongs to another account.',
            }, status),
          ),
        ).verifyPurchase(platform: 'ios', productId: 'p', token: 't');
      } catch (e) {
        return e;
      }
      return null;
    }

    final rejected = await fail(403);
    expect(rejected, isA<CreditRejectedException>());
    expect(
      (rejected! as CreditException).message,
      'This purchase belongs to another account.',
    );
    expect(await fail(400), isA<CreditRejectedException>());
    expect(await fail(409), isA<CreditRejectedException>());
    expect(await fail(401), isA<CreditSessionExpiredException>());
    expect(await fail(500), isA<CreditServerException>());
  });

  test('no connection is CreditOfflineException', () async {
    final s = _service(
      MockClient((_) async => throw const SocketException('no route')),
    );
    expect(s.wallet(), throwsA(isA<CreditOfflineException>()));
  });

  test('no session fails fast, without a request', () async {
    var sent = 0;
    final s = _service(
      MockClient((_) async {
        sent++;
        return _json({});
      }),
      token: null,
    );
    await expectLater(
      s.wallet(),
      throwsA(isA<CreditSessionExpiredException>()),
    );
    expect(sent, 0);
  });

  group('app config', () {
    test('flags parse and an unknown flag is off', () async {
      final cfg = await HttpAppConfigService(
        httpClient: MockClient(
          (_) async => _json({
            'flags': {'billing.plans.visible': true, 'analytics.enabled': true},
            'min_supported_app_version': '1.0.0',
            'billing_catalog_version': 3,
          }),
        ),
        baseUrl: _base,
      ).fetch();
      expect(cfg.plansVisible, isTrue);
      expect(cfg.flag('nope'), isFalse);
      expect(cfg.billingCatalogVersion, 3);
    });

    test(
      'anything but a 200, or no connection, is every flag off, never an error',
      () async {
        for (final client in [
          MockClient((_) async => _json({'error': 'x'}, 503)),
          MockClient((_) async => http.Response('not json', 200)),
          MockClient((_) async => throw const SocketException('down')),
        ]) {
          final cfg = await HttpAppConfigService(
            httpClient: client,
            baseUrl: _base,
          ).fetch();
          expect(cfg.plansVisible, isFalse);
        }
      },
    );
  });

  test(
    'a pack in the catalog grants credits including the bonus, as the server says',
    () {
      final pack = CreditPack.fromJson({
        'product_id': 'credits_300',
        'credits': 300,
        'bonus': 75,
        'badge': 'best_value',
      });
      expect(pack.credits, 300);
      expect(pack.badgeLabel, 'Best value');
    },
  );
}
