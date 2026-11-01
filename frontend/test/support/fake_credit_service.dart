import 'dart:async';

import 'package:professional_connections_platform/core/models/credits.dart';
import 'package:professional_connections_platform/core/services/credit_service.dart';

/// A scriptable [CreditService] for widget tests. Every answer is a field
/// a test sets; every call is recorded.
class FakeCreditService implements CreditService {
  FakeCreditService({
    this.walletResult = const Wallet(
      balance: 60,
      held: 0,
      available: 60,
      debt: 0,
    ),
    this.entitlementsResult = Entitlements.fallback,
    this.catalogResult = Catalog.empty,
  });

  Wallet walletResult;
  Object? walletError;

  /// Held open until completed, to test the loading state.
  Completer<void>? walletGate;
  int walletCalls = 0;

  /// History pages by cursor ('' is the first page).
  Map<String, LedgerPage> ledgerPages = {'': LedgerPage.empty};
  Object? ledgerError;
  final List<String?> ledgerCursors = [];

  /// What each quote call answers, in order. The last one repeats. A
  /// non-[CreditQuote] entry is thrown.
  List<Object> quoteScript = [
    const CreditQuote(
      cost: 10,
      priceVersion: 1,
      coveredByPlan: false,
      balanceAvailable: 60,
      limits: CreationLimits.fallback,
    ),
  ];
  final List<({int capacity, DateTime windowStart})> quoteCalls = [];

  Entitlements entitlementsResult;
  Object? entitlementsError;

  Catalog catalogResult;
  Object? catalogError;
  int catalogCalls = 0;

  PurchaseGrant? verifyResult;
  Object? verifyError;
  final List<({String platform, String productId, String token})> verifyCalls =
      [];

  @override
  Future<Wallet> wallet() async {
    walletCalls++;
    if (walletGate != null) await walletGate!.future;
    if (walletError != null) throw walletError!;
    return walletResult;
  }

  @override
  Future<LedgerPage> ledger({String? cursor}) async {
    ledgerCursors.add(cursor);
    if (ledgerError != null) throw ledgerError!;
    return ledgerPages[cursor ?? ''] ?? LedgerPage.empty;
  }

  @override
  Future<CreditQuote> quote({
    required int capacity,
    required DateTime windowStart,
  }) async {
    quoteCalls.add((capacity: capacity, windowStart: windowStart));
    final next = quoteScript.length > 1
        ? quoteScript.removeAt(0)
        : quoteScript.first;
    if (next is CreditQuote) return next;
    throw next;
  }

  @override
  Future<Entitlements> entitlements() async {
    if (entitlementsError != null) throw entitlementsError!;
    return entitlementsResult;
  }

  @override
  Future<Catalog> catalog() async {
    catalogCalls++;
    if (catalogError != null) throw catalogError!;
    return catalogResult;
  }

  @override
  Future<PurchaseGrant> verifyPurchase({
    required String platform,
    required String productId,
    required String token,
  }) async {
    verifyCalls.add((platform: platform, productId: productId, token: token));
    if (verifyError != null) throw verifyError!;
    return verifyResult ??
        PurchaseGrant(
          productId: productId,
          creditsGranted: 50,
          alreadyProcessed: false,
          wallet: walletResult,
        );
  }
}

CreditQuote quoteOf(
  int cost, {
  int available = 60,
  bool plan = false,
  int version = 1,
}) => CreditQuote(
  cost: cost,
  priceVersion: version,
  coveredByPlan: plan,
  balanceAvailable: available,
  limits: CreationLimits.fallback,
);
