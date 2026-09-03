import 'package:flutter_test/flutter_test.dart';
import 'package:professional_connections_platform/core/validation/validators.dart';

void main() {
  group('corporateEmail', () {
    test('rejects free providers', () {
      expect(Validators.corporateEmail('user@gmail.com'), isNotNull);
    });
    test('rejects role based mailboxes', () {
      expect(Validators.corporateEmail('hr@company.lk'), isNotNull);
    });
    test('accepts a corporate domain', () {
      expect(Validators.corporateEmail('user@company.lk'), isNull);
    });
  });

  group('phone', () {
    test('rejects short input', () {
      expect(Validators.phone('123'), isNotNull);
    });
    test('accepts Sri Lankan format', () {
      expect(Validators.phone('+94 77 123 4567'), isNull);
    });
  });
}
