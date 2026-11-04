// The constructor's public parameter names (subscriptionService/platform)
// deliberately differ from this class's private field names — an
// initializing formal would force them to match and leak the underscore
// into the public API (same reasoning as token_refresher.dart).
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:professional_connections_platform/core/analytics/analytics.dart';
import 'package:professional_connections_platform/core/analytics/flow_tracker.dart';
import 'package:professional_connections_platform/core/analytics/event_names.g.dart';
import 'package:professional_connections_platform/core/models/credits.dart';
import 'package:professional_connections_platform/core/services/credit_service.dart';
import 'package:professional_connections_platform/core/services/subscription_service.dart';

/// Drives the StoreKit2/Play Billing purchase flow (ADR-031, Slice B),
/// factored out of any widget so it's directly unit-testable without
/// faking `InAppPurchasePlatform`'s whole abstract surface — the same
/// "injectable test seam" convention already used elsewhere in this
/// codebase (e.g. `AndroidMapLocationStep`'s injectable `httpClient`,
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
///
/// Plan 29C adds credit packs. A product in [consumableIds] is bought with
/// `buyConsumable(autoConsume: false)` (the server consumes it with Google
/// after granting, so the app must not) and verified through
/// [CreditService.verifyPurchase]; everything else is a subscription, as
/// before. Every purchase carries [accountToken] as `applicationUserName`
/// (Apple's appAccountToken, Google's obfuscatedAccountId): the server
/// refuses a purchase without it, which is what stops a receipt being
/// replayed on another account. The rule above holds for both kinds.
///
/// # ONE LISTENER FOR THE APP (N1-D2)
///
/// [purchaseFlowProvider] holds the one instance, started after sign-in, so
/// a transaction the store redelivers is handled with no page open. With
/// [loadCatalog] set, a delivered product is routed by id against the
/// catalog: a credit pack to the credit verifier, a plan to the subscription
/// verifier. The catalog is awaited first, and a transaction the catalog
/// cannot place, or that arrives when there is no catalog, is left pending
/// and comes back on a later launch. Pages attach with [beginFlow].
class PurchaseFlowController extends ChangeNotifier {
  PurchaseFlowController({
    required SubscriptionService subscriptionService,
    required String platform,
    CreditService? creditService,
    Set<String> consumableIds = const {},
    String? accountToken,
    Stream<List<PurchaseDetails>>? purchaseUpdates,
    Future<void> Function(PurchaseDetails)? completePurchase,
    Future<bool> Function(PurchaseParam)? buyNonConsumable,
    Future<bool> Function(PurchaseParam)? buyConsumable,
    String? analyticsFlow,
    Future<Catalog> Function()? loadCatalog,
  }) : _subscriptionService = subscriptionService,
       _flow = analyticsFlow == null
           ? null
           : Analytics.instance.flow(analyticsFlow),
       _platform = platform,
       _loadCatalog = loadCatalog,
       _creditService = creditService,
       _consumableIds = consumableIds,
       accountToken = accountToken,
       _completePurchase =
           completePurchase ?? InAppPurchase.instance.completePurchase,
       _buyNonConsumable =
           buyNonConsumable ??
           ((param) =>
               InAppPurchase.instance.buyNonConsumable(purchaseParam: param)),
       _buyConsumable =
           buyConsumable ??
           ((param) => InAppPurchase.instance.buyConsumable(
             purchaseParam: param,
             autoConsume: false,
           )) {
    _subscription = (purchaseUpdates ?? InAppPurchase.instance.purchaseStream)
        .listen(_handleUpdates, onError: _handleStreamError);
  }

  final SubscriptionService _subscriptionService;
  final String _platform;
  final CreditService? _creditService;
  Set<String> _consumableIds;
  final Future<void> Function(PurchaseDetails) _completePurchase;
  final Future<bool> Function(PurchaseParam) _buyNonConsumable;
  final Future<bool> Function(PurchaseParam) _buyConsumable;

  /// The caller's account token. Set by the screen once the session is
  /// known; a purchase is not started without one.
  String? accountToken;

  /// Plan 29E: the buy-credits or subscribe funnel this purchase is part
  /// of (null: none). Choose, store sheet, confirmed by the server.
  FlowTracker? _flow;

  final Future<Catalog> Function()? _loadCatalog;
  Catalog? _catalog;

  String get _chooseStep => _flow?.flowId == AnalyticsFlow.subscribe
      ? AnalyticsFlowStep.subscribeChoosePlan
      : AnalyticsFlowStep.buyCreditsChoosePack;
  String get _sheetStep => _flow?.flowId == AnalyticsFlow.subscribe
      ? AnalyticsFlowStep.subscribeStoreSheet
      : AnalyticsFlowStep.buyCreditsStoreSheet;
  String get _confirmedStep => _flow?.flowId == AnalyticsFlow.subscribe
      ? AnalyticsFlowStep.subscribeConfirmed
      : AnalyticsFlowStep.buyCreditsConfirmed;

  /// A page opening: its funnel starts at the choose step, and it does not
  /// inherit a message from a background redelivery.
  void beginFlow(String flow) {
    _flow = Analytics.instance.flow(flow);
    errorMessage = null;
    startFlow();
  }

  /// Starts the funnel at its choose step (the page opening).
  void startFlow() => _flow?.stepViewed(_chooseStep);

  /// Abandons the funnel if it did not finish (the page closing).
  void endFlow() {
    _flow?.abandon(AnalyticsValue.flowAbandonedReasonBack);
    _flow = null;
  }

  late final StreamSubscription<List<PurchaseDetails>> _subscription;

  bool busy = false;
  String? errorMessage;
  SubscriptionStatus? lastVerifiedStatus;

  /// The server's answer to the last verified credit pack.
  PurchaseGrant? lastGrant;

  /// The credit pack product ids, from the catalog.
  set consumableIds(Set<String> ids) => _consumableIds = ids;

  Future<void> buy(ProductDetails product) async {
    errorMessage = null;
    final token = accountToken;
    if (token == null || token.isEmpty) {
      errorMessage = 'Sign in again to buy.';
      notifyListeners();
      return;
    }
    notifyListeners();
    _flow?.stepCompleted(_chooseStep);
    _flow?.stepViewed(_sheetStep);
    final param = PurchaseParam(
      productDetails: product,
      applicationUserName: token,
    );
    if (_consumableIds.contains(product.id)) {
      await _buyConsumable(param);
    } else {
      await _buyNonConsumable(param);
    }
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
          await _route(details, bought: true);
        case PurchaseStatus.restored:
          await _route(details);
        case PurchaseStatus.error:
          busy = false;
          // Never the store's own text: it is SDK vocabulary
          // ("BillingResponse.itemUnavailable", an SKErrorDomain code), and
          // the store has already shown the person its own explanation of
          // anything about their payment.
          errorMessage =
              'The purchase could not be completed. Please try again.';
          _flow?.abandon(AnalyticsValue.flowAbandonedReasonError);
          notifyListeners();
          await _completeIfPending(details);
        case PurchaseStatus.canceled:
          busy = false;
          errorMessage = null;
          _flow?.abandon(AnalyticsValue.flowAbandonedReasonClosed);
          notifyListeners();
          await _completeIfPending(details);
      }
    }
  }

  /// Sends a delivered product to the verifier its catalog entry names, or
  /// leaves it pending. See the class doc.
  Future<void> _route(PurchaseDetails details, {bool bought = false}) async {
    if (_loadCatalog == null) {
      return _verifyAndComplete(details, bought: bought);
    }
    final catalog = await _catalogFor(details.productID);
    if (catalog == null || !_places(catalog, details.productID)) {
      busy = false;
      if (bought) {
        errorMessage =
            'We could not confirm your purchase yet. We will try again the '
            'next time you open the app.';
        _flow?.abandon(AnalyticsValue.flowAbandonedReasonError);
      }
      notifyListeners();
      return;
    }
    _consumableIds = {for (final p in catalog.creditPacks) p.productId};
    await _verifyAndComplete(details, bought: bought);
  }

  bool _places(Catalog catalog, String productId) =>
      catalog.creditPacks.any((p) => p.productId == productId) ||
      catalog.plans.any((p) => p.productIds.containsValue(productId));

  /// The cached catalog if it knows [productId], otherwise a fresh one. Null
  /// if neither can be had: an unreachable server reads as an empty catalog
  /// (version 0), which is not an answer about this product.
  Future<Catalog?> _catalogFor(String productId) async {
    final cached = _catalog;
    if (cached != null && _places(cached, productId)) return cached;
    try {
      final fresh = await _loadCatalog!();
      if (fresh.version == 0) return cached;
      return _catalog = fresh;
    } catch (_) {
      return cached;
    }
  }

  Future<void> _verifyAndComplete(
    PurchaseDetails details, {
    bool bought = false,
  }) async {
    busy = true;
    errorMessage = null;
    notifyListeners();
    try {
      final credits = _creditService;
      if (credits != null && _consumableIds.contains(details.productID)) {
        lastGrant = await credits.verifyPurchase(
          platform: _platform,
          productId: details.productID,
          token: details.verificationData.serverVerificationData,
        );
      } else {
        lastVerifiedStatus = await _subscriptionService.verifyPurchase(
          platform: _platform,
          receiptOrToken: details.verificationData.serverVerificationData,
          productId: details.productID,
        );
      }
      // Only now — after the backend has confirmed verification — is the
      // transaction marked complete to the platform. The grant stands
      // whatever happens next: on Android the server has already consumed
      // a credit pack, and the plugin's own completion can then report an
      // error that is not one.
      try {
        await _completeIfPending(details);
      } catch (_) {
        // Granted; the store redelivers an unfinished transaction and the
        // server answers it as already processed.
      }
      if (bought) {
        // Confirmed by the server: the funnel's last step.
        _flow?.stepCompleted(_sheetStep);
        _flow?.stepViewed(_confirmedStep);
        _flow?.complete();
      }
      busy = false;
      notifyListeners();
    } catch (e) {
      if (bought) _flow?.abandon(AnalyticsValue.flowAbandonedReasonError);
      // Deliberately does NOT call completePurchase here: verification
      // failed, so the transaction is left pending and will be
      // re-delivered on the purchase stream (e.g. next launch) for retry,
      // rather than being silently finished/dropped.
      busy = false;
      errorMessage = switch (e) {
        SubscriptionException(:final message) => message,
        CreditException(:final message) => message,
        _ => 'Could not verify your purchase. Please try again.',
      };
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
