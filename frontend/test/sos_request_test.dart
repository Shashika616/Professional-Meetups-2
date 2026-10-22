import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:professional_connections_platform/core/models/trusted_contact.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/services/http_auth_service.dart';

HttpAuthService _serviceWith(http.Client client) => HttpAuthService(
  httpClient: client,
  baseUrl: 'http://localhost:8080',
  getAccessToken: () async => 'token',
);

http.Response _ok() => http.Response(jsonEncode({'contacts_notified': 2}), 200);

void main() {
  // The retry duplicate. The first attempt can reach the server and still
  // fail on the client — it timed out while the server was texting. The
  // retry must carry the same id so the server can tell it is the same
  // emergency and not alert everyone again.
  test('the automatic retry carries the same client_request_id', () async {
    final ids = <String?>[];
    var calls = 0;
    final client = MockClient((request) async {
      ids.add(
        (jsonDecode(request.body) as Map)['client_request_id'] as String?,
      );
      calls++;
      if (calls == 1) throw http.ClientException('connection reset');
      return _ok();
    });

    final notified = await _serviceWith(
      client,
    ).triggerSos(contextMessage: 'Triggered from the Safety Center.');

    expect(notified, 2);
    expect(ids, hasLength(2));
    expect(ids.first, isNotNull);
    expect(ids.first, isNotEmpty);
    expect(ids.last, ids.first, reason: 'the retry looked like a new SOS');
  });

  test('two separate SOS presses get different ids', () async {
    final ids = <String>[];
    final client = MockClient((request) async {
      ids.add((jsonDecode(request.body) as Map)['client_request_id'] as String);
      return _ok();
    });
    final service = _serviceWith(client);
    await service.triggerSos(contextMessage: 'x');
    await service.triggerSos(contextMessage: 'x');

    expect(
      ids[0],
      isNot(ids[1]),
      reason: 'a user pressing Retry must be able to send a new alert',
    );
    expect(ids[0], matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  // The timeout path itself (#78). The first attempt hangs; after 10 s it is
  // abandoned and the retry runs. A hang on both fails with the message the
  // safety screen shows, rather than waiting forever.
  test('a hung first attempt is retried after 10 seconds', () {
    fakeAsync((async) {
      var calls = 0;
      final client = MockClient((request) {
        calls++;
        return calls == 1
            ? Completer<http.Response>().future
            : Future.value(_ok());
      });
      int? notified;
      _serviceWith(
        client,
      ).triggerSos(contextMessage: 'x').then((n) => notified = n);

      async.elapse(const Duration(seconds: 9));
      expect(calls, 1, reason: 'retried before the 10 s deadline');
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(calls, 2);
      expect(notified, 2);
    });
  });

  test('two hung attempts fail with the call-emergency-services message', () {
    fakeAsync((async) {
      final client = MockClient((_) => Completer<http.Response>().future);
      Object? failure;
      _serviceWith(client).triggerSos(contextMessage: 'x').catchError((
        Object e,
      ) {
        failure = e;
        return 0;
      });

      async.elapse(const Duration(seconds: 21));
      async.flushMicrotasks();
      expect(failure, isA<AuthNetworkException>());
      expect(failure.toString(), contains('emergency services'));
    });
  });

  group('trusted contact consent state (#80)', () {
    Map<String, dynamic> json(String? status) => {
      'id': 'c1',
      'name': 'Amma',
      'phone_number': '+94771111111',
      'email': '',
      if (status != null) 'status': status,
    };

    test('reads pending and expired', () {
      expect(
        TrustedContact.fromJson(json('pending')).status,
        TrustedContactStatus.pending,
      );
      expect(
        TrustedContact.fromJson(json('expired')).status,
        TrustedContactStatus.expired,
      );
      expect(
        TrustedContact.fromJson(json('confirmed')).status,
        TrustedContactStatus.confirmed,
      );
    });

    // A server from before consent sends no status, and every contact it
    // has was alerted. Reading "absent" as anything but confirmed would show
    // a waiting label on contacts that are, in fact, protected.
    test('an absent or unknown status reads as confirmed', () {
      expect(
        TrustedContact.fromJson(json(null)).status,
        TrustedContactStatus.confirmed,
      );
      expect(
        TrustedContact.fromJson(json('something-new')).status,
        TrustedContactStatus.confirmed,
      );
    });
  });
}
