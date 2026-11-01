import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:professional_connections_platform/core/models/credits.dart';
import 'package:professional_connections_platform/core/models/user_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/app_config_service.dart';
import 'package:professional_connections_platform/core/services/credit_service.dart';
import 'package:professional_connections_platform/core/services/subscription_service.dart';
import 'package:professional_connections_platform/core/utils/uuid.dart';
import 'package:professional_connections_platform/features/credits/buy_credits_page.dart';
import 'package:professional_connections_platform/features/credits/credits_page.dart';

import 'support/fake_credit_service.dart';

const _userId = '00000000-0000-4000-8000-000000000040';

class _SignedIn extends AuthSessionNotifier {
  @override
  Future<AuthSessionState> build() async => const AuthSessionState(
    profile: UserProfile(id: _userId, fullName: 'Ada', trustLevel: 3),
  );
}

class _Store implements SubscriptionService {
  _Store(this.products, {this.error});

  final List<ProductDetails> products;
  final Object? error;

  @override
  Future<List<ProductDetails>> availableProducts(
    List<String> productIds,
  ) async {
    if (error != null) throw error!;
    return [
      for (final p in products)
        if (productIds.contains(p.id)) p,
    ];
  }

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

ProductDetails _product(String id, String price) => ProductDetails(
  id: id,
  title: id,
  description: '',
  price: price,
  rawPrice: 1,
  currencyCode: 'LKR',
);

LedgerEntry _entry(int id, int delta, String reason, [String refType = '']) =>
    LedgerEntry(
      id: id,
      delta: delta,
      reason: reason,
      refType: refType,
      balanceAfter: 0,
      createdAt: DateTime(2026, 10, 20),
    );

const _catalog = Catalog(
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

Widget _app(
  FakeCreditService credits,
  Widget home, {
  SubscriptionService? store,
}) => ProviderScope(
  overrides: [
    authSessionProvider.overrideWith(_SignedIn.new),
    creditServiceProvider.overrideWithValue(credits),
    subscriptionServiceProvider.overrideWithValue(store ?? _Store(const [])),
    appConfigProvider.overrideWith((ref) async => RemoteAppConfig.defaults),
  ],
  child: MaterialApp(home: home),
);

Future<void> _tall(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 3200);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
}

void main() {
  group('Credits page', () {
    testWidgets(
      'loading, then the balance, what is held, and the welcome credits about to decay',
      (tester) async {
        await _tall(tester);
        final credits = FakeCreditService(
          walletResult: Wallet(
            balance: 60,
            held: 10,
            available: 50,
            debt: 0,
            expiringSoon: [
              ExpiringCredits(
                kind: 'welcome',
                remaining: 54,
                nextDecayAt: DateTime(2026, 11, 9),
                nextDecayCredits: 6,
              ),
            ],
          ),
        )..walletGate = Completer<void>();
        await tester.pumpWidget(_app(credits, const CreditsPage()));
        await tester.pump();
        expect(
          find.byKey(const Key('creditsBalanceLoading'), skipOffstage: false),
          findsOneWidget,
        );

        credits.walletGate!.complete();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('creditsAvailable')), findsOneWidget);
        expect(find.text('50'), findsOneWidget);
        expect(
          find.text('10 credits held for a meetup being created'),
          findsOneWidget,
        );
        expect(find.text('54 welcome credits'), findsOneWidget);
        expect(find.text('6 credits expire on 9 Nov'), findsOneWidget);
        expect(find.byKey(const Key('creditsBuy')), findsOneWidget);
        expect(
          find.text('Restore purchases'),
          findsNothing,
          reason: 'consumables cannot be restored',
        );
      },
    );

    testWidgets('owed credits are explained', (tester) async {
      await _tall(tester);
      final credits = FakeCreditService(
        walletResult: const Wallet(balance: 0, held: 0, available: 0, debt: 30),
      );
      await tester.pumpWidget(_app(credits, const CreditsPage()));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('creditsDebt')), findsOneWidget);
      expect(find.textContaining('You owe 30 credits'), findsOneWidget);
    });

    testWidgets(
      'history in plain words, paginated, skipping lines that change nothing',
      (tester) async {
        await _tall(tester);
        final credits = FakeCreditService()
          ..ledgerPages = {
            '': LedgerPage(
              entries: [
                _entry(5, -10, 'capture', 'meetup'),
                _entry(4, 0, 'hold', 'credits'),
                _entry(3, 60, 'grant', 'welcome'),
              ],
              nextCursor: 'Mw',
            ),
            'Mw': LedgerPage(
              entries: [
                _entry(2, 50, 'grant', 'store_purchase'),
                _entry(1, -6, 'decay'),
              ],
            ),
          };
        await tester.pumpWidget(_app(credits, const CreditsPage()));
        await tester.pumpAndSettle();
        expect(find.text('Meetup created'), findsOneWidget);
        expect(find.text('Welcome credits'), findsOneWidget);
        expect(find.text('−10'), findsOneWidget);
        expect(find.text('+60'), findsOneWidget);
        expect(find.text('Purchased'), findsNothing);

        await tester.ensureVisible(find.byKey(const Key('creditsLoadMore')));
        await tester.tap(find.byKey(const Key('creditsLoadMore')));
        await tester.pumpAndSettle();
        expect(find.text('Purchased'), findsOneWidget);
        expect(find.text('Expired'), findsOneWidget);
        expect(find.byKey(const Key('creditsLoadMore')), findsNothing);
        expect(credits.ledgerCursors, [null, 'Mw']);
      },
    );

    testWidgets('empty history says so', (tester) async {
      await _tall(tester);
      await tester.pumpWidget(_app(FakeCreditService(), const CreditsPage()));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('creditsHistoryEmpty')), findsOneWidget);
      expect(find.text('No credit history yet'), findsOneWidget);
    });

    testWidgets('a server error offers a retry that recovers', (tester) async {
      await _tall(tester);
      final credits = FakeCreditService()
        ..ledgerError = const CreditServerException();
      await tester.pumpWidget(_app(credits, const CreditsPage()));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('creditsHistoryError')), findsOneWidget);
      expect(find.text('Something went wrong on our side'), findsOneWidget);

      credits
        ..ledgerError = null
        ..ledgerPages = {
          '': LedgerPage(entries: [_entry(1, 60, 'grant', 'welcome')]),
        };
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome credits'), findsOneWidget);
    });

    testWidgets('offline says so, for the balance and the history', (
      tester,
    ) async {
      await _tall(tester);
      final credits = FakeCreditService()
        ..walletError = const CreditOfflineException()
        ..ledgerError = const CreditOfflineException();
      await tester.pumpWidget(_app(credits, const CreditsPage()));
      await tester.pumpAndSettle();
      expect(find.text('You look offline'), findsNWidgets(2));
    });
  });

  group('Buy credits page', () {
    testWidgets(
      'packs from the catalog at the store\'s prices; one the store lacks is skipped',
      (tester) async {
        await _tall(tester);
        final credits = FakeCreditService(catalogResult: _catalog);
        final store = _Store([
          _product('credits_50', 'Rs 500.00'),
          _product('credits_120', 'Rs 1,100.00'),
        ]);
        await tester.pumpWidget(
          _app(
            credits,
            const BuyCreditsPage(platform: 'android'),
            store: store,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('pack-credits_50')), findsOneWidget);
        expect(find.byKey(const Key('pack-credits_120')), findsOneWidget);
        expect(find.byKey(const Key('pack-credits_300')), findsNothing);
        expect(find.text('Rs 500.00'), findsOneWidget);
        expect(find.text('Includes 20 credits bonus'), findsOneWidget);
        expect(find.text('Popular'), findsOneWidget);
        expect(find.text('60 credits'), findsOneWidget, reason: 'the balance');
      },
    );

    testWidgets(
      'buying: consumable with the account token, credited only when the server says so',
      (tester) async {
        await _tall(tester);
        final updates = StreamController<List<PurchaseDetails>>.broadcast();
        addTearDown(updates.close);
        final bought = <PurchaseParam>[];
        final completed = <PurchaseDetails>[];
        final credits = FakeCreditService(catalogResult: _catalog)
          ..verifyResult = const PurchaseGrant(
            productId: 'credits_50',
            creditsGranted: 50,
            alreadyProcessed: false,
            wallet: Wallet(balance: 110, held: 0, available: 110, debt: 0),
          );
        await tester.pumpWidget(
          _app(
            credits,
            BuyCreditsPage(
              platform: 'android',
              purchaseUpdates: updates.stream,
              buyConsumable: (p) async {
                bought.add(p);
                return true;
              },
              completePurchase: (d) async => completed.add(d),
            ),
            store: _Store([_product('credits_50', 'Rs 500.00')]),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('pack-credits_50')));
        await tester.pump();
        expect(bought.single.productDetails.id, 'credits_50');
        expect(bought.single.applicationUserName, accountToken(_userId));

        final details = PurchaseDetails(
          productID: 'credits_50',
          verificationData: PurchaseVerificationData(
            localVerificationData: 'l',
            serverVerificationData: 'purchase-token',
            source: 'google_play',
          ),
          transactionDate: null,
          status: PurchaseStatus.purchased,
        )..pendingCompletePurchase = true;
        updates.add([details]);
        await tester.pumpAndSettle();

        expect(credits.verifyCalls.single, (
          platform: 'android',
          productId: 'credits_50',
          token: 'purchase-token',
        ));
        expect(completed.single, same(details));
        expect(
          find.text('110 credits'),
          findsOneWidget,
          reason: 'the new balance',
        );
        expect(find.text('50 credits added.'), findsOneWidget);
      },
    );

    testWidgets('nothing on sale, and a store that fails, each say so', (
      tester,
    ) async {
      await _tall(tester);
      await tester.pumpWidget(
        _app(
          FakeCreditService(catalogResult: _catalog),
          const BuyCreditsPage(platform: 'ios'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('buyCreditsEmpty')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        _app(
          FakeCreditService(catalogResult: _catalog),
          const BuyCreditsPage(platform: 'ios'),
          store: _Store(
            const [],
            error: const SubscriptionException('store down'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('The store did not answer'), findsOneWidget);
    });

    testWidgets('an offline catalog says so', (tester) async {
      await _tall(tester);
      final credits = FakeCreditService()
        ..catalogError = const CreditOfflineException();
      await tester.pumpWidget(
        _app(credits, const BuyCreditsPage(platform: 'ios')),
      );
      await tester.pumpAndSettle();
      expect(find.text('You look offline'), findsOneWidget);
    });
  });
}
