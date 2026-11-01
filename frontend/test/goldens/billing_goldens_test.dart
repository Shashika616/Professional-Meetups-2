// Golden images of the plan 29C screens, dark and light.
//
// macOS only: goldens are only comparable on the platform that drew them,
// and these load a system font (Arial) so the text is readable rather than
// flutter_test's block glyphs. CI runs on Linux and skips them; the images
// in test/goldens/ are the record, and copies sit beside the 29C report.
//
// Regenerate with: flutter test --update-goldens test/goldens/
@Tags(['golden'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:professional_connections_platform/core/models/credits.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/app_config_service.dart';
import 'package:professional_connections_platform/core/services/credit_service.dart';
import 'package:professional_connections_platform/core/services/subscription_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/features/credits/buy_credits_page.dart';
import 'package:professional_connections_platform/features/credits/credits_page.dart';
import 'package:professional_connections_platform/features/premium/premium_page.dart';

import '../support/fake_credit_service.dart';

const _fontRegular = '/System/Library/Fonts/Supplemental/Arial.ttf';
const _fontBold = '/System/Library/Fonts/Supplemental/Arial Bold.ttf';
final _canRun =
    Platform.isMacOS &&
    File(_fontRegular).existsSync() &&
    File(_fontBold).existsSync();

class _SignedIn extends AuthSessionNotifier {
  @override
  Future<AuthSessionState> build() async => const AuthSessionState(
    profile: UserProfile(
      id: '00000000-0000-4000-8000-000000000040',
      fullName: 'Ada',
      trustLevel: 3,
    ),
  );
}

class _Store implements SubscriptionService {
  _Store(this.products);

  final List<ProductDetails> products;

  @override
  Future<List<ProductDetails>> availableProducts(
    List<String> productIds,
  ) async => [
    for (final p in products)
      if (productIds.contains(p.id)) p,
  ];

  @override
  Future<SubscriptionStatus> currentStatus() async => const SubscriptionStatus(
    tier: SubscriptionTier.free,
    status: SubscriptionLifecycleStatus.none,
  );

  @override
  Future<void> restorePurchases() async {}

  @override
  Future<SubscriptionStatus> verifyPurchase({
    required String platform,
    required String receiptOrToken,
    required String productId,
  }) async => throw UnimplementedError();
}

ProductDetails _p(String id, String price) => ProductDetails(
  id: id,
  title: id,
  description: '',
  price: price,
  rawPrice: 1,
  currencyCode: 'LKR',
);

final _year = DateTime.now().year;

LedgerEntry _e(int id, int delta, String reason, String refType, int day) =>
    LedgerEntry(
      id: id,
      delta: delta,
      reason: reason,
      refType: refType,
      balanceAfter: 0,
      createdAt: DateTime(_year, 3, day),
    );

const _packs = Catalog(
  version: 1,
  creditPacks: [
    CreditPack(productId: 'credits_50', credits: 50, sort: 1),
    CreditPack(
      productId: 'credits_120',
      credits: 120,
      bonus: 20,
      badge: 'popular',
      sort: 2,
    ),
    CreditPack(
      productId: 'credits_300',
      credits: 300,
      bonus: 75,
      badge: 'best_value',
      sort: 3,
    ),
  ],
  plansVisible: false,
  plans: [],
);

Catalog _plans(bool visible) => Catalog(
  version: 1,
  creditPacks: const [],
  plansVisible: visible,
  plans: [
    if (visible) ...[
      const CatalogPlan(
        code: 'pro',
        productIds: {'ios': 'premium_monthly', 'android': 'premium_monthly'},
        period: 'month',
        title: 'TieHere Pro',
        perks: [
          '10 meetups a month included',
          'Up to 30 people per meetup',
          'Schedule up to 30 days ahead',
        ],
      ),
      const CatalogPlan(
        code: 'pro',
        productIds: {'ios': 'premium_yearly', 'android': 'premium_yearly'},
        period: 'year',
        title: 'TieHere Pro',
        perks: [
          '10 meetups a month included',
          'Up to 30 people per meetup',
          'Schedule up to 30 days ahead',
        ],
        featured: true,
      ),
    ],
  ],
  termsUrl: 'https://example.com/terms',
  privacyUrl: 'https://example.com/privacy',
);

Future<void> _shot(
  WidgetTester tester,
  String name,
  Widget page, {
  required FakeCreditService credits,
  SubscriptionService? store,
}) async {
  for (final mode in AppThemeMode.values) {
    AppPalette.setMode(mode);
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authSessionProvider.overrideWith(_SignedIn.new),
          creditServiceProvider.overrideWithValue(credits),
          subscriptionServiceProvider.overrideWithValue(
            store ?? _Store(const []),
          ),
          appConfigProvider.overrideWith(
            (ref) async => RemoteAppConfig.defaults,
          ),
          subscriptionStatusProvider.overrideWith(
            (ref) async => const SubscriptionStatus(
              tier: SubscriptionTier.free,
              status: SubscriptionLifecycleStatus.none,
            ),
          ),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: mode == AppThemeMode.light
                ? Brightness.light
                : Brightness.dark,
            useMaterial3: true,
            fontFamily: 'Roboto',
            scaffoldBackgroundColor: AppPalette.onyx,
            appBarTheme: const AppBarTheme(
              backgroundColor: Colors.transparent,
              elevation: 0,
              centerTitle: true,
            ),
          ),
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('$name-${mode.name}.png'),
    );
    await tester.pumpWidget(const SizedBox());
  }
  AppPalette.setMode(AppThemeMode.dark);
  tester.view.reset();
}

Future<bool> _noBuy(PurchaseParam _) async => true;
Future<void> _noComplete(PurchaseDetails _) async {}

void main() {
  setUpAll(() async {
    if (!_canRun) return;
    final loader = FontLoader('Roboto')
      ..addFont(
        Future.value(
          ByteData.sublistView(File(_fontRegular).readAsBytesSync()),
        ),
      )
      ..addFont(
        Future.value(ByteData.sublistView(File(_fontBold).readAsBytesSync())),
      );
    await loader.load();
  });

  testWidgets(
    'credits page with a balance, expiring welcome credits and history',
    (tester) async {
      final credits =
          FakeCreditService(
              walletResult: Wallet(
                balance: 64,
                held: 10,
                available: 54,
                debt: 0,
                expiringSoon: [
                  ExpiringCredits(
                    kind: 'welcome',
                    remaining: 42,
                    nextDecayAt: DateTime(_year, 3, 23),
                    nextDecayCredits: 6,
                  ),
                ],
              ),
            )
            ..ledgerPages = {
              '': LedgerPage(
                entries: [
                  _e(4, -12, 'capture', 'meetup', 18),
                  _e(3, 50, 'grant', 'store_purchase', 16),
                  _e(2, -6, 'decay', '', 14),
                  _e(1, 60, 'grant', 'welcome', 7),
                ],
              ),
            };
      await _shot(
        tester,
        'credits_page',
        const CreditsPage(),
        credits: credits,
      );
    },
    skip: !_canRun,
  );

  testWidgets('credits page, empty history and an offline balance', (
    tester,
  ) async {
    final credits = FakeCreditService()
      ..walletError = const CreditOfflineException();
    await _shot(
      tester,
      'credits_page_offline',
      const CreditsPage(),
      credits: credits,
    );
  }, skip: !_canRun);

  testWidgets('buy credits with store prices', (tester) async {
    await _shot(
      tester,
      'buy_credits',
      BuyCreditsPage(
        platform: 'ios',
        purchaseUpdates: const Stream.empty(),
        buyConsumable: _noBuy,
        completePurchase: _noComplete,
      ),
      credits: FakeCreditService(catalogResult: _packs),
      store: _Store([
        _p('credits_50', 'Rs 490.00'),
        _p('credits_120', 'Rs 1,090.00'),
        _p('credits_300', 'Rs 2,490.00'),
      ]),
    );
  }, skip: !_canRun);

  testWidgets('premium page with plans from the catalog', (tester) async {
    await _shot(
      tester,
      'premium_plans',
      PremiumPage(
        platform: 'ios',
        purchaseUpdates: const Stream.empty(),
        buyNonConsumable: _noBuy,
        completePurchase: _noComplete,
      ),
      credits: FakeCreditService(catalogResult: _plans(true)),
      store: _Store([
        _p('premium_monthly', 'Rs 1,490.00'),
        _p('premium_yearly', 'Rs 12,900.00'),
      ]),
    );
  }, skip: !_canRun);

  testWidgets('premium page with plans hidden', (tester) async {
    await _shot(
      tester,
      'premium_hidden',
      PremiumPage(
        platform: 'ios',
        purchaseUpdates: const Stream.empty(),
        buyNonConsumable: _noBuy,
        completePurchase: _noComplete,
      ),
      credits: FakeCreditService(catalogResult: _plans(false)),
    );
  }, skip: !_canRun);
}
