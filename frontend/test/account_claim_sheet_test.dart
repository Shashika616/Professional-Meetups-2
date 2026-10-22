import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/storage/session_storage.dart';
import 'package:professional_connections_platform/core/widgets/app_sheet.dart';
import 'package:professional_connections_platform/core/widgets/otp_box_field.dart';
import 'package:professional_connections_platform/features/onboarding/account_claim_sheet.dart';
import 'package:professional_connections_platform/features/onboarding/onboarding_flow.dart';

import 'support/fake_auth_service.dart';
import 'support/fake_meetup_service.dart';
import 'support/fake_secure_storage_platform.dart';

/// The claim-an-existing-account sheet: what it says, what it refuses to
/// say, and that finishing it is a real sign-in.
void main() {
  const claim = AccountClaimRequiredException(
    ticket: 'signed-ticket',
    email: 'ada@example.com',
    resendAfterSeconds: 60,
    message: 'An account already exists for this email address.',
  );

  late ImmediateAuthService auth;
  late SecureSessionStorage storage;

  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
    storage = SecureSessionStorage(storage: const FlutterSecureStorage());
    auth = ImmediateAuthService();
  });

  /// Mounts a page that raises the sheet on a tap, and records what the
  /// sheet resolved to — the signal the sign-in path switches on.
  Future<List<bool?>> pumpSheet(WidgetTester tester) async {
    final resolved = <bool?>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(auth),
          sessionStorageProvider.overrideWithValue(storage),
          meetupServiceProvider.overrideWithValue(ImmediateMeetupService()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () async => resolved.add(
                    await showAccountClaimSheet(context, claim: claim),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return resolved;
  }

  Future<void> enterCode(WidgetTester tester, String code) async {
    await tester.enterText(find.byType(OtpBoxField), code);
    await tester.pumpAndSettle();
  }

  testWidgets('says an account exists and names the address, and nothing '
      'else about it', (tester) async {
    await pumpSheet(tester);

    expect(find.byType(AppSheet), findsOneWidget);
    expect(find.text('This email is already in use'), findsOneWidget);
    expect(find.textContaining('ada@example.com'), findsOneWidget);
    // Both controls the spec asks for, by name.
    expect(find.text('Verify'), findsOneWidget);
    expect(find.byKey(const Key('cancelAccountClaim')), findsOneWidget);

    // THE DISCLOSURE RULE. The existing account's holder is 'Ada Lovelace'
    // in the fake, and the sheet must not have learned it from anywhere —
    // the server never sends it, and nothing here may infer it.
    expect(find.textContaining('Ada Lovelace'), findsNothing);
  });

  testWidgets('does not send a second code on open — the 409 already sent '
      'one', (tester) async {
    await pumpSheet(tester);

    expect(
      auth.resendClaimCalls,
      0,
      reason:
          'a send on mount would burn the cooldown and show an error for a '
          'code already sitting in the inbox',
    );
  });

  testWidgets('the right code signs in to the EXISTING account', (
    tester,
  ) async {
    final resolved = await pumpSheet(tester);
    await enterCode(tester, '123456');
    await tester.tap(find.text('Verify'));
    await tester.pumpAndSettle();

    expect(auth.claimedWithTicket, 'signed-ticket');
    expect(resolved, [true], reason: 'the sign-in path switches on this');
    expect(find.byType(AppSheet), findsNothing);

    // A real sign-in: the session is stored, and it is the existing
    // account rather than a fresh one.
    final stored = await storage.loadSession();
    expect(stored?.userId, 'existing-user-1');
    expect(stored?.isNewUser, isFalse);
  });

  testWidgets('a wrong code keeps the sheet open and shows the reason', (
    tester,
  ) async {
    final resolved = await pumpSheet(tester);
    await enterCode(tester, '000000');
    await tester.tap(find.text('Verify'));
    await tester.pumpAndSettle();

    expect(find.byType(AppSheet), findsOneWidget, reason: 'it must not close');
    expect(find.textContaining('not right'), findsOneWidget);
    expect(resolved, isEmpty);
    expect(await storage.loadSession(), isNull);
  });

  testWidgets('CANCEL closes it without signing in', (tester) async {
    final resolved = await pumpSheet(tester);
    await tester.tap(find.byKey(const Key('cancelAccountClaim')));
    await tester.pumpAndSettle();

    expect(find.byType(AppSheet), findsNothing);
    expect(resolved, [null], reason: 'null is "cancelled", not "claimed"');
    expect(await storage.loadSession(), isNull);
  });

  testWidgets('a tap outside does not dismiss it — the two ways out are '
      'both deliberate', (tester) async {
    await pumpSheet(tester);

    // The barrier sits over the whole screen above the sheet.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byType(AppSheet), findsOneWidget);
  });

  // THE WIRING SEAM. A collision has to OPEN this sheet, not land in a
  // toast that tells the person their address is taken and offers them
  // nothing to do about it. Driven through the real OnboardingFlow so the
  // path under test is the one a user actually takes.
  testWidgets('a colliding provider sign-in opens the sheet instead of '
      'reporting an error', (tester) async {
    auth.googleClaimRequired = claim;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(auth),
          sessionStorageProvider.overrideWithValue(storage),
          meetupServiceProvider.overrideWithValue(ImmediateMeetupService()),
        ],
        child: const MaterialApp(home: OnboardingFlow()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();

    expect(find.byType(AppSheet), findsOneWidget);
    expect(find.text('This email is already in use'), findsOneWidget);

    // Finishing it from here signs in for real.
    await enterCode(tester, '123456');
    await tester.tap(find.text('Verify'));
    await tester.pumpAndSettle();

    expect((await storage.loadSession())?.userId, 'existing-user-1');
  });
}
