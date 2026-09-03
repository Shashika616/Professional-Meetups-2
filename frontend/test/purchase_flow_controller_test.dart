import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:professional_connections_platform/core/services/subscription_service.dart';
import 'package:professional_connections_platform/features/premium/purchase_flow_controller.dart';

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
  late PurchaseFlowController controller;

  setUp(() {
    subscriptionService = _FakeSubscriptionService();
    purchaseUpdates = StreamController<List<PurchaseDetails>>.broadcast();
    completedPurchases = [];
    boughtParams = [];
    controller = PurchaseFlowController(
      subscriptionService: subscriptionService,
      platform: 'ios',
      purchaseUpdates: purchaseUpdates.stream,
      completePurchase: (details) async {
        completedPurchases.add(details);
      },
      buyNonConsumable: (param) async {
        boughtParams.add(param);
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
    'error status surfaces the message and completes a pending transaction',
    () async {
      final details = _details(
        status: PurchaseStatus.error,
        pendingCompletePurchase: true,
        error: IAPError(source: 'test', code: 'boom', message: 'card declined'),
      );
      purchaseUpdates.add([details]);
      await pumpEventQueue();

      expect(controller.busy, isFalse);
      expect(controller.errorMessage, 'card declined');
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
  });

  test('restore() delegates to SubscriptionService.restorePurchases', () async {
    await controller.restore();

    expect(subscriptionService.restorePurchasesCalls, 1);
  });
}
