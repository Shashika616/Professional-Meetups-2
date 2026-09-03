// The constructor's public parameter names (subscriptionService/platform)
// deliberately differ from this class's private field names — an
// initializing formal would force them to match and leak the underscore
// into the public API (same reasoning as token_refresher.dart).
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:professional_connections_platform/core/services/subscription_service.dart';

/// Drives the StoreKit2/Play Billing purchase flow (ADR-031, Slice B),
/// factored out of any widget so it's directly unit-testable without
/// faking `InAppPurchasePlatform`'s whole abstract surface — the same
/// "injectable test seam" convention already used elsewhere in this
/// codebase (e.g. `StadiaMapLocationStep`'s injectable `httpClient`,
/// `debugStadiaApiKeyOverride`). [purchaseUpdates] defaults to the real
/// `InAppPurchase.instance.purchaseStream` and [completePurchase]/[buy]
/// default to the real `InAppPurchase.instance` calls; tests supply their
/// own controlled stream and scriptable callbacks instead, feeding plain
/// constructed [PurchaseDetails] objects with no platform channel involved.
///
/// Handles every [PurchaseStatus] value:
/// - `pending` — shows busy state, no backend call yet.
/// - `purchased` / `restored` — sends the receipt/token to
///   [SubscriptionService.verifyPurchase] for server-side verification;
///   **`completePurchase` is only called after that succeeds** (ADR-031's
///   "do not mark a mobile purchase complete to the platform before the
///   backend has confirmed verification" rule) — on a verification
///   failure the transaction is deliberately left pending so the store
///   redelivers it on the purchase stream for a retry, rather than being
///   silently dropped.
/// - `error` / `canceled` — surfaces the message, completes the platform
///   transaction if one is pending (nothing to verify — the purchase
///   itself didn't succeed).
class PurchaseFlowController extends ChangeNotifier {
  PurchaseFlowController({
    required SubscriptionService subscriptionService,
    required String platform,
    Stream<List<PurchaseDetails>>? purchaseUpdates,
    Future<void> Function(PurchaseDetails)? completePurchase,
    Future<bool> Function(PurchaseParam)? buyNonConsumable,
  }) : _subscriptionService = subscriptionService,
       _platform = platform,
       _completePurchase =
           completePurchase ?? InAppPurchase.instance.completePurchase,
       _buyNonConsumable =
           buyNonConsumable ??
           ((param) =>
               InAppPurchase.instance.buyNonConsumable(purchaseParam: param)) {
    _subscription = (purchaseUpdates ?? InAppPurchase.instance.purchaseStream)
        .listen(_handleUpdates, onError: _handleStreamError);
  }

  final SubscriptionService _subscriptionService;
  final String _platform;
  final Future<void> Function(PurchaseDetails) _completePurchase;
  final Future<bool> Function(PurchaseParam) _buyNonConsumable;
  late final StreamSubscription<List<PurchaseDetails>> _subscription;

  bool busy = false;
  String? errorMessage;
  SubscriptionStatus? lastVerifiedStatus;

  Future<void> buy(ProductDetails product) async {
    errorMessage = null;
    notifyListeners();
    await _buyNonConsumable(PurchaseParam(productDetails: product));
  }

  Future<void> restore() => _subscriptionService.restorePurchases();

  Future<void> _handleUpdates(List<PurchaseDetails> updates) async {
    for (final details in updates) {
      switch (details.status) {
        case PurchaseStatus.pending:
          busy = true;
          errorMessage = null;
          notifyListeners();
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _verifyAndComplete(details);
        case PurchaseStatus.error:
          busy = false;
          errorMessage =
              details.error?.message ?? 'The purchase could not be completed.';
          notifyListeners();
          await _completeIfPending(details);
        case PurchaseStatus.canceled:
          busy = false;
          errorMessage = null;
          notifyListeners();
          await _completeIfPending(details);
      }
    }
  }

  Future<void> _verifyAndComplete(PurchaseDetails details) async {
    busy = true;
    errorMessage = null;
    notifyListeners();
    try {
      final status = await _subscriptionService.verifyPurchase(
        platform: _platform,
        receiptOrToken: details.verificationData.serverVerificationData,
        productId: details.productID,
      );
      lastVerifiedStatus = status;
      // Only now — after the backend has confirmed verification — is the
      // transaction marked complete to the platform.
      await _completeIfPending(details);
      busy = false;
      notifyListeners();
    } catch (e) {
      // Deliberately does NOT call completePurchase here: verification
      // failed, so the transaction is left pending and will be
      // re-delivered on the purchase stream (e.g. next launch) for retry,
      // rather than being silently finished/dropped.
      busy = false;
      errorMessage = e is SubscriptionException
          ? e.message
          : 'Could not verify your purchase. Please try again.';
      notifyListeners();
    }
  }

  Future<void> _completeIfPending(PurchaseDetails details) async {
    if (details.pendingCompletePurchase) {
      await _completePurchase(details);
    }
  }

  void _handleStreamError(Object error) {
    busy = false;
    errorMessage = 'The purchase could not be completed.';
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
