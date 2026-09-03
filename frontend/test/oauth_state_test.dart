import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/services/oauth_state.dart';

void main() {
  test('generate produces a fresh value every call', () {
    final first = OAuthState.generate();
    final second = OAuthState.generate();

    expect(first, isNot(equals(second)));
    expect(RegExp(r'^[A-Za-z0-9\-_]+$').hasMatch(first), isTrue);
  });
}
