import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:professional_connections_platform/core/config/app_version.dart';
import 'package:professional_connections_platform/core/services/client_info_http_client.dart';
import 'package:professional_connections_platform/core/utils/uuid.dart';

void main() {
  test('AppVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final line = RegExp(
      r'^version:\s*(\S+)$',
      multiLine: true,
    ).firstMatch(pubspec)!.group(1);
    expect(
      line,
      AppVersion.header,
      reason: 'bump lib/core/config/app_version.dart with pubspec.yaml',
    );
  });

  test('every request carries X-App-Version and X-Platform', () async {
    late http.BaseRequest seen;
    final client = ClientInfoHttpClient(
      MockClient((request) async {
        seen = request;
        return http.Response('{}', 200);
      }),
      platform: 'ios',
    );
    await client.get(Uri.parse('http://localhost/v1/app-config'));
    expect(seen.headers['X-App-Version'], '1.1.0+7');
    expect(seen.headers['X-Platform'], 'ios');
  });

  test('the account token is the server\'s UUIDv5', () {
    // Vectors from Python's uuid.uuid5, which Go's uuid.NewSHA1 agrees with
    // (RFC 4122 §4.3), under billing.AccountTokenNamespace.
    expect(
      accountToken('00000000-0000-4000-8000-000000000040'),
      '86c0ac9d-aaeb-55cd-b903-7c60e6c93b6e',
    );
    expect(
      accountToken('3F2A9C1E-1B2C-4D5E-8F90-A1B2C3D4E5F6'),
      '26a3a2ba-e010-50e0-9ff5-f8345c5e515c',
    );
  });

  test('uuidV4 is a random version 4 UUID', () {
    final a = uuidV4();
    expect(
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(a),
      isTrue,
    );
    expect(uuidV4(), isNot(a));
  });
}
