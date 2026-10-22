import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/widgets/secure_screen.dart';

void main() {
  final calls = <String>[];

  setUp(() {
    calls.clear();
    SecureScreen.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SecureScreen.channel, (call) async {
          calls.add(call.method);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SecureScreen.channel, null);
  });

  // #94: an OTP, the trusted-contact list and the SOS sheet stay out of
  // screenshots and the app switcher while they are up — and only then.
  testWidgets('secures while mounted and releases when gone', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: SecureScreen(child: Text('code: 123456'))),
    );
    expect(calls, ['enable']);

    await tester.pumpWidget(const MaterialApp(home: Text('home')));
    expect(
      calls,
      ['enable', 'disable'],
      reason:
          'leaving a secure screen must release FLAG_SECURE, or every '
          'later screen stays unscreenshottable',
    );
  });

  // A sheet that is secure over a page that is secure: closing the sheet
  // must not unprotect the page underneath.
  testWidgets('stays secure until the last secure screen goes', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SecureScreen(
          child: Column(children: [SecureScreen(child: Text('sheet'))]),
        ),
      ),
    );
    expect(calls, ['enable'], reason: 'nesting enabled it twice');

    await tester.pumpWidget(
      const MaterialApp(home: SecureScreen(child: Text('page'))),
    );
    expect(calls, [
      'enable',
    ], reason: 'the inner one went; the page is still up');
    expect(SecureScreen.activeCount, 1);

    await tester.pumpWidget(const MaterialApp(home: Text('home')));
    expect(calls, ['enable', 'disable']);
  });

  testWidgets('a missing platform channel does not break the screen', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SecureScreen.channel, (call) async {
          throw PlatformException(code: 'unavailable');
        });
    await tester.pumpWidget(
      const MaterialApp(home: SecureScreen(child: Text('still here'))),
    );
    expect(find.text('still here'), findsOneWidget);
  });
}
