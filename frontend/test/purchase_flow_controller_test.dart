import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:professional_connections_platform/core/models/credits.dart';
import 'package:professional_connections_platform/core/services/credit_service.dart';
import 'package:professional_connections_platform/core/services/subscription_service.dart';
import 'package:professional_connections_platform/features/premium/purchase_flow_controller.dart';

import 'support/fake_credit_service.dart';

class _FakeSubscriptionService implements SubscriptionService {
  int verifyPurchaseCalls = 0;
  int restorePurchasesCalls = 0;
  ({String platform, String receiptOrToken, String productId})? lastVerifyArgs;

  /// Script: set to throw to simulate a backend verification failure.
  Object? verifyPurchaseError;
  SubscriptionStatus verifyPurchaseResult = const SubscriptionStatus(
    tier: SubscriptionTier.premium,
    status: SubscriptionLifecycleStatus.active,
  );

  @override
  Future<SubscriptionStatus> verifyPurchase({
    required String platform,
    required String receiptOrToken,
    required String productId,
  }) async {
    verifyPurchaseCalls++;
    lastVerifyArgs = (
      platform: platform,
      receiptOrToken: receiptOrToken,
      productId: productId,
    );
    if (verifyPurchaseError != null) {
      throw verifyPurchaseError!;
    }
    return verifyPurchaseResult;
  }

  @override
  Future<void> restorePurchases() async {
    restorePurchasesCalls++;
  }

  @override
  Future<SubscriptionStatus> currentStatus() async => const SubscriptionStatus(
    tier: SubscriptionTier.free,
    status: SubscriptionLifecycleStatus.none,
  );

  @override
  Future<List<ProductDetails>> availableProducts(
    List<String> productIds,
  ) async => const [];
}

PurchaseDetails _details({
  required PurchaseStatus status,
  String productID = 'premium_monthly',
  bool pendingCompletePurchase = false,
  IAPError? error,
}) {
  final details = PurchaseDetails(
    productID: productID,
    verificationData: PurchaseVerificationData(
      localVerificationData: 'local',
      serverVerificationData: 'server-token',
      source: 'test',
    ),
    transactionDate: null,
    status: status,
  );
  details.pendingCompletePurchase = pendingCompletePurchase;
  details.error = error;
  return details;
}

void main() {
  late _FakeSubscriptionService subscriptionService;
  late StreamController<List<PurchaseDetails>> purchaseUpdates;
  late List<PurchaseDetails> completedPurchases;
  late List<PurchaseParam> boughtParams;
  late List<PurchaseParam> boughtConsumables;
  late FakeCreditService creditService;
  late PurchaseFlowController controller;

  setUp(() {
    subscriptionService = _FakeSubscriptionService();
    creditService = FakeCreditService();
    purchaseUpdates = StreamController<List<PurchaseDetails>>.broadcast();
    completedPurchases = [];
    boughtParams = [];
    boughtConsumables = [];
    controller = PurchaseFlowController(
      subscriptionService: subscriptionService,
      creditService: creditService,
      consumableIds: const {'credits_50'},
      accountToken: '86c0ac9d-aaeb-55cd-b903-7c60e6c93b6e',
      platform: 'ios',
      purchaseUpdates: purchaseUpdates.stream,
      completePurchase: (details) async {
        completedPurchases.add(details);
      },
      buyNonConsumable: (param) async {
        boughtParams.add(param);
        return true;
      },
      buyConsumable: (param) async {
        boughtConsumables.add(param);
        return true;
      },
    );
  });

  tearDown(() {
    controller.dispose();
    purchaseUpdates.close();
  });

  test('pending sets busy without touching the backend', () async {
    purchaseUpdates.add([_details(status: PurchaseStatus.pending)]);
    await pumpEventQueue();

    expect(controller.busy, isTrue);
    expect(subscriptionService.verifyPurchaseCalls, 0);
    expect(completedPurchases, isEmpty);
  });

  test('purchased sends the receipt to the backend and only completes the '
      'platform transaction after verification succeeds', () async {
    final details = _details(
      status: PurchaseStatus.purchased,
      pendingCompletePurchase: true,
    );
    purchaseUpdates.add([details]);
    await pumpEventQueue();

    expect(subscriptionService.verifyPurchaseCalls, 1);
    expect(subscriptionService.lastVerifyArgs?.platform, 'ios');
    expect(subscriptionService.lastVerifyArgs?.receiptOrToken, 'server-token');
    expect(subscriptionService.lastVerifyArgs?.productId, 'premium_monthly');
    expect(completedPurchases, [details]);
    expect(controller.busy, isFalse);
    expect(controller.errorMessage, isNull);
    expect(controller.lastVerifiedStatus?.isEntitled, isTrue);
  });

  test('restored is verified exactly like a fresh purchase', () async {
    final details = _details(
      status: PurchaseStatus.restored,
      pendingCompletePurchase: true,
    );
    purchaseUpdates.add([details]);
    await pumpEventQueue();

    expect(subscriptionService.verifyPurchaseCalls, 1);
    expect(completedPurchases, [details]);
  });

  test(
    'a failed backend verification leaves the transaction pending — '
    'completePurchase is never called, so the store can redeliver it',
    () async {
      subscriptionService.verifyPurchaseError = const SubscriptionException(
        'purchase could not be verified',
      );
      final details = _details(
        status: PurchaseStatus.purchased,
        pendingCompletePurchase: true,
      );
      purchaseUpdates.add([details]);
      await pumpEventQueue();

      expect(subscriptionService.verifyPurchaseCalls, 1);
      expect(completedPurchases, isEmpty);
      expect(controller.busy, isFalse);
      expect(controller.errorMessage, 'purchase could not be verified');
      expect(controller.lastVerifiedStatus, isNull);
    },
  );

  test(
    'error status shows a readable message and completes a pending transaction',
    () async {
      final details = _details(
        status: PurchaseStatus.error,
        pendingCompletePurchase: true,
        error: IAPError(source: 'test', code: 'boom', message: 'card declined'),
      );
      purchaseUpdates.add([details]);
      await pumpEventQueue();

      expect(controller.busy, isFalse);
      expect(
        controller.errorMessage,
        'The purchase could not be completed. Please try again.',
        reason: 'the store SDK text is never shown',
      );
      expect(subscriptionService.verifyPurchaseCalls, 0);
      expect(completedPurchases, [details]);
    },
  );

  test(
    'canceled status clears busy/error and completes a pending transaction',
    () async {
      final details = _details(
        status: PurchaseStatus.canceled,
        pendingCompletePurchase: true,
      );
      purchaseUpdates.add([details]);
      await pumpEventQueue();

      expect(controller.busy, isFalse);
      expect(controller.errorMessage, isNull);
      expect(subscriptionService.verifyPurchaseCalls, 0);
      expect(completedPurchases, [details]);
    },
  );

  test(
    'error/canceled do not complete a transaction with nothing pending',
    () async {
      purchaseUpdates.add([_details(status: PurchaseStatus.canceled)]);
      await pumpEventQueue();

      expect(completedPurchases, isEmpty);
    },
  );

  test('buy() forwards the product through buyNonConsumable', () async {
    final product = ProductDetails(
      id: 'premium_monthly',
      title: 'Premium Monthly',
      description: 'Premium',
      price: r'$9.99',
      rawPrice: 9.99,
      currencyCode: 'USD',
    );

    await controller.buy(product);

    expect(boughtParams, hasLength(1));
    expect(boughtParams.single.productDetails.id, 'premium_monthly');
    expect(
      boughtParams.single.applicationUserName,
      '86c0ac9d-aaeb-55cd-b903-7c60e6c93b6e',
    );
    expect(boughtConsumables, isEmpty);
  });

  // --- plan 29C: credit packs ---

  ProductDetails pack() => ProductDetails(
    id: 'credits_50',
    title: '50 credits',
    description: 'Credits',
    price: 'Rs 500.00',
    rawPrice: 500,
    currencyCode: 'LKR',
  );

  test(
    'a credit pack is bought as a consumable, carrying the account token',
    () async {
      await controller.buy(pack());
      expect(boughtConsumables, hasLength(1));
      expect(boughtConsumables.single.productDetails.id, 'credits_50');
      expect(
        boughtConsumables.single.applicationUserName,
        '86c0ac9d-aaeb-55cd-b903-7c60e6c93b6e',
      );
      expect(boughtParams, isEmpty);
    },
  );

  test('without an account token nothing is bought', () async {
    controller.accountToken = null;
    await controller.buy(pack());
    expect(boughtConsumables, isEmpty);
    expect(controller.errorMessage, isNotNull);
  });

  test(
    'a consumable is completed only after the server confirms the grant',
    () async {
      final verified = Completer<void>();
      final details = _details(
        status: PurchaseStatus.purchased,
        productID: 'credits_50',
        pendingCompletePurchase: true,
      );
      // Hold the server's answer: nothing may complete until it arrives.
      creditService.verifyError = null;
      final gated = _GatedCreditService(creditService, verified.future);
      // Its own stream: the setUp controller must not see this purchase.
      final updates = StreamController<List<PurchaseDetails>>();
      addTearDown(updates.close);
      final c = PurchaseFlowController(
        subscriptionService: subscriptionService,
        creditService: gated,
        consumableIds: const {'credits_50'},
        accountToken: 'tok',
        platform: 'android',
        purchaseUpdates: updates.stream,
        completePurchase: (d) async => completedPurchases.add(d),
        buyNonConsumable: (_) async => true,
        buyConsumable: (_) async => true,
      );
      addTearDown(c.dispose);
      updates.add([details]);
      await pumpEventQueue();
      expect(
        completedPurchases,
        isEmpty,
        reason: 'completed before the server answered',
      );
      verified.complete();
      await pumpEventQueue();
      expect(creditService.verifyCalls.single, (
        platform: 'android',
        productId: 'credits_50',
        token: 'server-token',
      ));
      expect(
        subscriptionService.verifyPurchaseCalls,
        0,
        reason: 'a pack goes to the credits verify, not the subscription one',
      );
      expect(
        completedPurchases.where((d) => identical(d, details)),
        hasLength(1),
      );
      expect(c.lastGrant?.creditsGranted, 50);
    },
  );

  test(
    'a server failure leaves the consumable pending for the store to redeliver',
    () async {
      creditService.verifyError = const CreditUnavailableException();
      final details = _details(
        status: PurchaseStatus.purchased,
        productID: 'credits_50',
        pendingCompletePurchase: true,
      );
      purchaseUpdates.add([details]);
      await pumpEventQueue();
      expect(completedPurchases, isEmpty);
      expect(controller.lastGrant, isNull);
      expect(
        controller.errorMessage,
        const CreditUnavailableException().message,
      );
      expect(controller.busy, isFalse);
    },
  );

  test(
    'a completion error after the grant is not reported as a failure',
    () async {
      final c = PurchaseFlowController(
        subscriptionService: subscriptionService,
        creditService: creditService,
        consumableIds: const {'credits_50'},
        accountToken: 'tok',
        platform: 'android',
        purchaseUpdates: purchaseUpdates.stream,
        completePurchase: (_) async =>
            throw StateError('already consumed by the server'),
        buyNonConsumable: (_) async => true,
        buyConsumable: (_) async => true,
      );
      addTearDown(c.dispose);
      purchaseUpdates.add([
        _details(
          status: PurchaseStatus.purchased,
          productID: 'credits_50',
          pendingCompletePurchase: true,
        ),
      ]);
      await pumpEventQueue();
      expect(c.lastGrant, isNotNull);
      expect(c.errorMessage, isNull);
    },
  );

  test('restore() delegates to SubscriptionService.restorePurchases', () async {
    await controller.restore();

    expect(subscriptionService.restorePurchasesCalls, 1);
  });
}

/// Holds every verifyPurchase until [gate] completes.
class _GatedCreditService extends FakeCreditService {
  _GatedCreditService(this._inner, this._gate);

  final FakeCreditService _inner;
  final Future<void> _gate;

  @override
  Future<PurchaseGrant> verifyPurchase({
    required String platform,
    required String productId,
    required String token,
  }) async {
    await _gate;
    return _inner.verifyPurchase(
      platform: platform,
      productId: productId,
      token: token,
    );
  }
}
