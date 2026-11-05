import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/app_config_service.dart';
import 'package:professional_connections_platform/core/services/legal_service.dart';
import 'package:professional_connections_platform/features/legal/legal_acceptance_page.dart';
import 'package:professional_connections_platform/features/legal/legal_document_page.dart';
import 'package:professional_connections_platform/features/verification/corporate_email_verification_page.dart';

class _Legal implements LegalService {
  bool accepted = false;
  final saved = <String>[];
  Object? acceptError;
  Object? statusError;
  Object? documentsError;
  int documentReads = 0;

  @override
  Future<LegalDocuments> documents() async {
    documentReads++;
    if (documentsError != null) throw documentsError!;
    return _documents;
  }

  static const _documents = LegalDocuments(
    version: 'v2',
    terms:
        '# Terms\n\n## 1. Eligibility\n\nYou must be **18**.\n\n- One rule\n',
    privacy: '# Privacy\n\nWe keep little.\n',
  );

  @override
  Future<bool> hasAccepted() async {
    if (statusError != null) throw statusError!;
    return accepted;
  }

  @override
  Future<void> accept(String version) async {
    if (acceptError != null) throw acceptError!;
    saved.add(version);
    accepted = true;
  }
}

class _SignedOut extends AuthSessionNotifier {
  @override
  Future<AuthSessionState> build() async => const AuthSessionState();
}

const _required = RemoteAppConfig(flags: {'legal.acceptance.required': true});

void main() {
  late _Legal legal;

  setUp(() => legal = _Legal());

  Widget app(Widget home) => ProviderScope(
    overrides: [
      legalServiceProvider.overrideWithValue(legal),
      authSessionProvider.overrideWith(_SignedOut.new),
    ],
    child: MaterialApp(home: home),
  );

  ProviderContainer container(RemoteAppConfig config) {
    final c = ProviderContainer(
      overrides: [
        legalServiceProvider.overrideWithValue(legal),
        authSessionProvider.overrideWith(_SignedOut.new),
        appConfigProvider.overrideWith((ref) async => config),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('who is asked', () {
    test('nobody while the flag is off', () async {
      final c = container(RemoteAppConfig.defaults);
      expect(await c.read(legalAcceptancePendingProvider.future), isFalse);
    });

    test('someone who has not agreed', () async {
      final c = container(_required);
      expect(await c.read(legalAcceptancePendingProvider.future), isTrue);
    });

    test('not someone who has', () async {
      legal.accepted = true;
      final c = container(_required);
      expect(await c.read(legalAcceptancePendingProvider.future), isFalse);
    });

    test('a failed check locks nobody out', () async {
      legal.statusError = const LegalException('offline');
      final c = container(_required);
      expect(await c.read(legalAcceptancePendingProvider.future), isFalse);
    });
  });

  testWidgets('continuing needs the box ticked, and saves the version', (
    tester,
  ) async {
    await tester.pumpWidget(app(const LegalAcceptancePage()));
    await tester.pump();
    await tester.tap(find.text('Agree and continue'));
    await tester.pump();
    expect(legal.saved, isEmpty);

    await tester.tap(find.byKey(const Key('legal-agree')));
    await tester.pump();
    await tester.tap(find.text('Agree and continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(legal.saved, ['v2']);
  });

  testWidgets('a refusal says why and records nothing', (tester) async {
    legal.acceptError = const LegalException('These terms have changed.');
    await tester.pumpWidget(app(const LegalAcceptancePage()));
    await tester.pump();
    await tester.tap(find.byKey(const Key('legal-agree')));
    await tester.pump();
    await tester.tap(find.text('Agree and continue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('These terms have changed.'), findsOneWidget);
    expect(legal.saved, isEmpty);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('both documents open from the page', (tester) async {
    await tester.pumpWidget(app(const LegalAcceptancePage()));
    await tester.pump();
    await tester.tap(find.text('Terms and Conditions'));
    await tester.pumpAndSettle();
    expect(find.byType(LegalDocumentPage), findsOneWidget);
  });

  testWidgets('a document reads as headings, text and bullets', (tester) async {
    await tester.pumpWidget(
      app(const LegalDocumentPage(document: LegalDocument.terms)),
    );
    await tester.pumpAndSettle();
    expect(find.text('1. Eligibility'), findsOneWidget);
    expect(find.text('One rule'), findsOneWidget);
    expect(find.textContaining('##'), findsNothing);
    expect(find.textContaining('**'), findsNothing);
  });

  testWidgets('a failed read says so at once, and Try again reads again', (
    tester,
  ) async {
    legal.documentsError = const LegalException('nothing published');
    await tester.pumpWidget(
      app(const LegalDocumentPage(document: LegalDocument.terms)),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Try again'), findsOneWidget);
    expect(legal.documentReads, 1, reason: 'it must not retry by itself');

    legal.documentsError = null;
    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Try again'), findsNothing);
    expect(legal.documentReads, 2);
  });

  testWidgets('the company field shows the saved name, not the domain', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        const CorporateEmailVerificationPage(
          currentDomainHint: 'wso2.com',
          currentCompanyName: 'WSO2 LLC',
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Currently verified: WSO2 LLC'), findsOneWidget);
    expect(find.text('WSO2 LLC'), findsOneWidget);
    expect(find.textContaining('wso2.com'), findsNothing);
  });

  testWidgets('with no saved name it falls back to the domain', (tester) async {
    await tester.pumpWidget(
      app(const CorporateEmailVerificationPage(currentDomainHint: 'wso2.com')),
    );
    await tester.pump();
    expect(find.text('Currently verified: wso2.com'), findsOneWidget);
  });
}
