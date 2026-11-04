import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:professional_connections_platform/core/models/credits.dart';
import 'package:professional_connections_platform/core/services/subscription_service.dart';
import 'package:professional_connections_platform/features/premium/purchase_flow_controller.dart';

import 'support/fake_credit_service.dart';

class _Subscriptions implements SubscriptionService {
  final verified = <String>[];

  @override
  Future<SubscriptionStatus> verifyPurchase({
    required String platform,
    required String receiptOrToken,
    required String productId,
  }) async {
    verified.add(productId);
    return const SubscriptionStatus(
      tier: SubscriptionTier.premium,
      status: SubscriptionLifecycleStatus.active,
    );
  }

  @override
  Future<void> restorePurchases() async {}

  @override
  Future<SubscriptionStatus> currentStatus() async => const SubscriptionStatus(
    tier: SubscriptionTier.free,
    status: SubscriptionLifecycleStatus.none,
  );

  @override
  Future<List<ProductDetails>> availableProducts(List<String> ids) async =>
      const [];
}

const _catalog = Catalog(
  version: 3,
  creditPacks: [CreditPack(productId: 'credits_50', credits: 50, sort: 1)],
  plansVisible: true,
  plans: [
    CatalogPlan(
      code: 'premium',
      productIds: {'ios': 'premium_monthly', 'android': 'premium'},
      period: 'month',
      title: 'Premium',
    ),
  ],
);

PurchaseDetails _delivered(String product, PurchaseStatus status) =>
    PurchaseDetails(
      productID: product,
      verificationData: PurchaseVerificationData(
        localVerificationData: 'local',
        serverVerificationData: 'token',
        source: 'test',
      ),
      transactionDate: null,
      status: status,
    )..pendingCompletePurchase = true;

void main() {
  late _Subscriptions subscriptions;
  late FakeCreditService credits;
  late StreamController<List<PurchaseDetails>> updates;
  late List<String> completed;

  setUp(() {
    subscriptions = _Subscriptions();
    credits = FakeCreditService();
    updates = StreamController.broadcast();
    completed = [];
  });

  PurchaseFlowController controller(Future<Catalog> Function() loadCatalog) {
    final c = PurchaseFlowController(
      subscriptionService: subscriptions,
      creditService: credits,
      platform: 'ios',
      purchaseUpdates: updates.stream,
      completePurchase: (d) async => completed.add(d.productID),
      buyNonConsumable: (_) async => true,
      buyConsumable: (_) async => true,
      loadCatalog: loadCatalog,
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> settle() => pumpEventQueue();

  test(
    'a redelivered credit pack waits for the catalog, then is granted',
    () async {
      final catalog = Completer<Catalog>();
      final c = controller(() => catalog.future);
      updates.add([_delivered('credits_50', PurchaseStatus.restored)]);
      await settle();
      expect(
        subscriptions.verified,
        isEmpty,
        reason: 'routed before the catalog',
      );
      expect(credits.verifyCalls, isEmpty);
      expect(completed, isEmpty);

      catalog.complete(_catalog);
      await settle();
      expect(credits.verifyCalls, hasLength(1));
      expect(subscriptions.verified, isEmpty);
      expect(completed, ['credits_50']);
      expect(c.lastGrant, isNotNull);
    },
  );

  test('a plan goes to the subscription verifier', () async {
    controller(() async => _catalog);
    updates.add([_delivered('premium_monthly', PurchaseStatus.restored)]);
    await settle();
    expect(subscriptions.verified, ['premium_monthly']);
    expect(credits.verifyCalls, isEmpty);
    expect(completed, ['premium_monthly']);
  });

  test('a product the catalog does not place stays pending', () async {
    controller(() async => _catalog);
    updates.add([_delivered('mystery', PurchaseStatus.restored)]);
    await settle();
    expect(subscriptions.verified, isEmpty);
    expect(credits.verifyCalls, isEmpty);
    expect(completed, isEmpty);
  });

  for (final (name, load) in <(String, Future<Catalog> Function())>[
    ('fails', () async => throw StateError('offline')),
    ('is the empty 503 answer', () async => Catalog.empty),
  ]) {
    test('no catalog: it stays pending when the load $name', () async {
      final c = controller(load);
      updates.add([_delivered('credits_50', PurchaseStatus.purchased)]);
      await settle();
      expect(credits.verifyCalls, isEmpty);
      expect(subscriptions.verified, isEmpty);
      expect(completed, isEmpty);
      expect(c.busy, isFalse);
      expect(c.errorMessage, contains('next time you open the app'));
    });
  }

  test('the catalog is cached between purchases', () async {
    var loads = 0;
    controller(() async {
      loads++;
      return _catalog;
    });
    updates.add([_delivered('credits_50', PurchaseStatus.restored)]);
    await settle();
    updates.add([_delivered('premium_monthly', PurchaseStatus.restored)]);
    await settle();
    expect(loads, 1);
  });

  test('a page that opens does not inherit a background message', () async {
    final c = controller(() async => throw StateError('offline'));
    updates.add([_delivered('credits_50', PurchaseStatus.purchased)]);
    await settle();
    expect(c.errorMessage, isNotNull);
    c.beginFlow('buy_credits');
    expect(c.errorMessage, isNull);
    c.endFlow();
  });
}
