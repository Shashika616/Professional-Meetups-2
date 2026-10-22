import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/country.dart';

void main() {
  group('splitPhoneNumber', () {
    test('an empty or null value opens on the default country', () {
      expect(splitPhoneNumber(null).country.iso, 'LK');
      expect(splitPhoneNumber(null).localNumber, '');
      expect(splitPhoneNumber('').country.iso, 'LK');
    });

    test('an E.164 number resolves to its own country, not the default', () {
      // The bug this guards: editing an already-verified +971 number used
      // to re-prefix it with +94, so saving it again changed the number.
      final uae = splitPhoneNumber('+971501234567');
      expect(uae.country.iso, 'AE');
      expect(uae.localNumber, '501234567');
    });

    test('the longest matching dial code wins', () {
      // +1809 and +1 both prefix this string. Taking the first match in
      // list order would call a Dominican number American.
      final dom = splitPhoneNumber('+18095551234');
      expect(dom.country.iso, 'DO');
      expect(dom.localNumber, '5551234');

      final us = splitPhoneNumber('+15551234567');
      expect(us.country.iso, 'US');
    });

    test('an unrecognised prefix keeps the digits rather than dropping '
        'them', () {
      final odd = splitPhoneNumber('+99912345678');
      expect(odd.country, kDefaultCountry);
      expect(
        odd.localNumber,
        '+99912345678',
        reason: 'the user must still see what they typed',
      );
    });

    test('a value with no leading + is treated as a local number', () {
      final local = splitPhoneNumber('712345678');
      expect(local.country, kDefaultCountry);
      expect(local.localNumber, '712345678');
    });
  });

  group('Country', () {
    test('search matches name, ISO code and dial code', () {
      const lk = Country('LK', 'Sri Lanka', '+94');
      expect(lk.matches('sri'), isTrue);
      expect(lk.matches('LANKA'), isTrue, reason: 'case-insensitive');
      expect(lk.matches('lk'), isTrue);
      expect(lk.matches('94'), isTrue);
      expect(lk.matches('+94'), isTrue);
      expect(lk.matches(''), isTrue, reason: 'empty query matches all');
      expect(lk.matches('germany'), isFalse);
    });

    test('the flag is derived from the ISO code', () {
      // Regional indicators: L = U+1F1F1, K = U+1F1F0.
      expect(
        const Country('LK', 'Sri Lanka', '+94').flag,
        '\u{1F1F1}\u{1F1F0}',
      );
    });

    test('every dial code is well formed and every ISO code unique', () {
      final seen = <String>{};
      for (final c in kCountries) {
        expect(
          c.dialCode,
          matches(RegExp(r'^\+\d{1,4}$')),
          reason: '${c.name} has a malformed dial code',
        );
        expect(c.iso, matches(RegExp(r'^[A-Z]{2}$')), reason: c.name);
        expect(seen.add(c.iso), isTrue, reason: '${c.iso} is listed twice');
      }
      expect(kCountries, contains(isA<Country>()));
    });

    test('the default country is in the list', () {
      expect(kCountries.any((c) => c.iso == kDefaultCountry.iso), isTrue);
    });
  });
}
