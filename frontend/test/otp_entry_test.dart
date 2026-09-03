import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/verification/widgets/otp_entry.dart';

Widget _appWith({
  required Future<int> Function() onSend,
  required Future<void> Function(String code) onSubmit,
}) {
  return MaterialApp(
    home: Scaffold(
      body: OtpEntry(onSend: onSend, onSubmit: onSubmit),
    ),
  );
}

void main() {
  testWidgets(
    'shows the optimistic 60s countdown from the very first frame, before '
    'onSend has resolved at all — this is the whole point of the '
    'optimistic-send UX (a slow backend must not stall this screen)',
    (tester) async {
      final neverCompletes = Completer<int>();
      await tester.pumpWidget(
        _appWith(onSend: () => neverCompletes.future, onSubmit: (_) async {}),
      );

      // No pump beyond the initial one — onSend is still in flight.
      expect(
        find.text('Resend code in ${OtpEntry.resendCooldownSeconds}s'),
        findsOneWidget,
      );
    },
  );

  testWidgets('calls onSend automatically on mount — no separate "send" tap '
      'is needed once this widget appears', (tester) async {
    var sendCalls = 0;
    await tester.pumpWidget(
      _appWith(
        onSend: () async {
          sendCalls++;
          return 60;
        },
        onSubmit: (_) async {},
      ),
    );
    await tester.pump();

    expect(sendCalls, 1);
  });

  testWidgets(
    'reconciles the countdown to the server value once onSend resolves, if '
    'it differs from the optimistic default',
    (tester) async {
      await tester.pumpWidget(
        _appWith(onSend: () async => 45, onSubmit: (_) async {}),
      );

      // First frame: optimistic default.
      expect(
        find.text('Resend code in ${OtpEntry.resendCooldownSeconds}s'),
        findsOneWidget,
      );

      // After onSend resolves: reconciled to the server's real value.
      await tester.pump();
      expect(find.text('Resend code in 45s'), findsOneWidget);
    },
  );

  testWidgets('fault tolerance: when onSend fails, the countdown resets to 0 '
      'immediately (not left running for the full cooldown) and the failure '
      'is shown inline — the user can retry right away instead of waiting '
      'out a cooldown for a code that was never sent', (tester) async {
    await tester.pumpWidget(
      _appWith(
        onSend: () async =>
            throw const AuthNetworkException('backend unreachable'),
        onSubmit: (_) async {},
      ),
    );
    await tester.pump();

    expect(find.text('Resend code'), findsOneWidget);
    expect(find.textContaining('Resend code in'), findsNothing);
    expect(find.text('backend unreachable'), findsOneWidget);
  });

  testWidgets('VERIFY stays disabled until all 6 digits are entered, then '
      'submits the code', (tester) async {
    String? submitted;
    await tester.pumpWidget(
      _appWith(
        onSend: () async => 60,
        onSubmit: (code) async => submitted = code,
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), '123');
    await tester.pump();
    await tester.tap(find.byType(PrimaryButton));
    await tester.pump();
    expect(submitted, isNull); // 3 digits — PrimaryButton ignored the tap.

    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    await tester.tap(find.byType(PrimaryButton));
    await tester.pump();
    await tester.pump();

    expect(submitted, '123456');
  });

  testWidgets(
    'a wrong code shows the error message but does not reset the timer',
    (tester) async {
      await tester.pumpWidget(
        _appWith(
          onSend: () async => 30,
          onSubmit: (_) async =>
              throw const InvalidVerificationCodeException('Wrong code.'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Resend code in 25s'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '000000');
      await tester.pump();
      await tester.tap(find.byType(PrimaryButton));
      await tester.pump();
      await tester.pump();

      expect(find.text('Wrong code.'), findsOneWidget);
      // The countdown kept running through the failed attempt — no free
      // reset for a wrong guess (frontend/PLAN.md's addendum, Step 4).
      expect(find.text('Resend code in 25s'), findsOneWidget);
    },
  );

  testWidgets('resend before the cooldown elapses is a no-op; after it '
      'elapses it reseeds the timer from the server value', (tester) async {
    var sendCalls = 0;
    await tester.pumpWidget(
      _appWith(
        onSend: () async {
          sendCalls++;
          return sendCalls == 1 ? 2 : 45;
        },
        onSubmit: (_) async {},
      ),
    );
    await tester.pump(); // resolve the initial (optimistic) send → 2s

    // Cooldown still active — tapping "Resend code in 2s" must not fire.
    await tester.tap(
      find.textContaining('Resend code in'),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(sendCalls, 1);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Resend code'), findsOneWidget);

    await tester.tap(find.text('Resend code'));
    await tester.pump();
    await tester.pump();

    expect(sendCalls, 2);
    expect(find.text('Resend code in 45s'), findsOneWidget);
  });
}
