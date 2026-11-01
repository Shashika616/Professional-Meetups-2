import 'package:in_app_purchase/in_app_purchase.dart' show ProductDetails;

/// Contract for subscription/billing (ADR-031, Slice B) — same
/// `abstract interface class` + real-implementation pattern as
/// [AuthService]/[MeetupService] (`CLAUDE.md`'s "Service-contract
/// pattern"). [availableProducts] is the one method that talks to the
/// device's app store directly (via `in_app_purchase`) rather than the
/// backend — querying a product catalog is inherently a client-side,
/// store-specific operation the backend has no reason to proxy; every
/// other method goes through the gateway to `billing`.
///
/// The operating principle this interface exists to enforce, same as
/// everywhere else in this app: **the client never decides subscription
/// status — it only displays what the server's [currentStatus] returns**.
/// A purchase's receipt/token is never treated as "I'm Premium now" on its
/// own; [verifyPurchase] is what turns a client-held receipt into a
/// server-confirmed subscription state, and nothing in the app should read
/// [SubscriptionStatus] from anywhere but this service.
abstract interface class SubscriptionService {
  /// The caller's current subscription state — always backend-sourced,
  /// never derived from local purchase-stream state.
  Future<SubscriptionStatus> currentStatus();

  /// Queries the device's app store (StoreKit2/Play Billing) for the
  /// purchasable product catalog. Purely client-side/store-side — the
  /// backend has no product catalog of its own to proxy this through.
  Future<List<ProductDetails>> availableProducts(List<String> productIds);

  /// Sends a completed purchase's receipt/token to the backend's
  /// VerifyPurchase RPC for server-side verification (ADR-031 §2 step 2)
  /// — called once per `PurchaseStatus.purchased`/`.restored`
  /// purchase-stream update, never used to *initiate* a purchase itself
  /// (that's `InAppPurchase.instance.buyNonConsumable`, called directly
  /// by the purchase-flow UI, which then listens for the resulting stream
  /// update and calls this). Returns the resulting, backend-confirmed
  /// subscription state on success — the caller must not mark the
  /// purchase complete to the platform until this succeeds.
  Future<SubscriptionStatus> verifyPurchase({
    required String platform,
    required String receiptOrToken,
    required String productId,
  });

  /// Triggers `in_app_purchase`'s restore flow (Apple's required "Restore
  /// Purchases" action for any app with non-consumable/subscription
  /// purchases). Restored purchases arrive on the same purchase stream as
  /// a fresh purchase, as `PurchaseStatus.restored` — the purchase-flow UI
  /// re-verifies each one via [verifyPurchase] exactly like a fresh
  /// purchase; this method only kicks the store-side restore off.
  Future<void> restorePurchases();
}

/// Mirrors the backend's `SubscriptionResponse`/`subscriptions` shape
/// (ADR-031 §1) — `free`/`premium`/`enterprise` tier, backend-owned
/// status. `none` status pairs with `free` tier for a user who has never
/// purchased anything (GetSubscriptionStatus synthesizes this rather than
/// the client treating "no subscription" as an error case).
enum SubscriptionTier { free, premium, enterprise }

enum SubscriptionLifecycleStatus {
  none,
  active,
  gracePeriod,
  pastDue,
  canceled,
  expired,
  revoked,
}

/// True for active/gracePeriod — the one place "does this status count as
/// entitled" is defined client-side, mirroring the backend's own
/// `Status.IsEntitled` (services/billing/internal/repository/repository.go)
/// so the two can't silently drift on what "entitled" means.
extension SubscriptionLifecycleStatusEntitlement
    on SubscriptionLifecycleStatus {
  bool get isEntitled =>
      this == SubscriptionLifecycleStatus.active ||
      this == SubscriptionLifecycleStatus.gracePeriod;
}

class SubscriptionStatus {
  const SubscriptionStatus({
    required this.tier,
    required this.status,
    this.platform,
    this.productId,
    this.currentPeriodEnd,
    this.autoRenewStatus = false,
    this.planCode = '',
    this.serverEntitled,
  });

  final SubscriptionTier tier;
  final SubscriptionLifecycleStatus status;
  final String? platform;

  /// The store product the active subscription was bought as (one of the
  /// `premium*ProductId` constants), when the backend reports it; null
  /// otherwise. With three tiers on sale (Plan 20 Fix 3) this is how the
  /// Premium screen knows which row to mark CURRENT PLAN. The wire key is
  /// `product_id`; a backend that does not send it yet leaves this null and
  /// the screen still treats the account as entitled, it just cannot point
  /// at one tier.
  final String? productId;
  final DateTime? currentPeriodEnd;
  final bool autoRenewStatus;

  /// The plan the subscription is for (`pro`, `enterprise`), when any.
  final String planCode;

  /// The server's own `entitled` (plan 29B), which also accounts for a
  /// grace period that has ended. Older answers without it fall back to
  /// the status.
  final bool? serverEntitled;

  bool get isEntitled => serverEntitled ?? status.isEntitled;

  /// Reads both the 29B shape (`plan_code`, `entitled`, `auto_renew`) and
  /// the older one (`tier`, `auto_renew_status`).
  factory SubscriptionStatus.fromJson(Map<String, dynamic> json) {
    final status = _statusFromWire(json['status'] as String? ?? 'none');
    final planCode = json['plan_code'] as String? ?? '';
    final entitled = json['entitled'] as bool?;
    final tier = json.containsKey('tier')
        ? _tierFromWire(json['tier'] as String? ?? 'free')
        : planCode == 'enterprise'
        ? SubscriptionTier.enterprise
        : (entitled ?? status.isEntitled) && planCode.isNotEmpty
        ? SubscriptionTier.premium
        : SubscriptionTier.free;
    final end = (json['current_period_end_unix_seconds'] as num?)?.toInt() ?? 0;
    final productId = json['product_id'] as String?;
    return SubscriptionStatus(
      tier: tier,
      status: status,
      platform: json['platform'] as String?,
      productId: (productId == null || productId.isEmpty) ? null : productId,
      currentPeriodEnd: end > 0
          ? DateTime.fromMillisecondsSinceEpoch(end * 1000)
          : null,
      autoRenewStatus:
          json['auto_renew'] as bool? ??
          json['auto_renew_status'] as bool? ??
          false,
      planCode: planCode,
      serverEntitled: entitled,
    );
  }

  static SubscriptionTier _tierFromWire(String value) => switch (value) {
    'premium' => SubscriptionTier.premium,
    'enterprise' => SubscriptionTier.enterprise,
    _ => SubscriptionTier.free,
  };

  static SubscriptionLifecycleStatus _statusFromWire(String value) =>
      switch (value) {
        'active' => SubscriptionLifecycleStatus.active,
        'grace_period' => SubscriptionLifecycleStatus.gracePeriod,
        'past_due' => SubscriptionLifecycleStatus.pastDue,
        'canceled' => SubscriptionLifecycleStatus.canceled,
        'expired' => SubscriptionLifecycleStatus.expired,
        'revoked' => SubscriptionLifecycleStatus.revoked,
        _ => SubscriptionLifecycleStatus.none,
      };
}

/// Thrown by [SubscriptionService] methods on a server-rejected/failed
/// call — mirrors `MeetupException`'s own shape in `meetup_service.dart`.
class SubscriptionException implements Exception {
  const SubscriptionException(this.message);
  final String message;

  @override
  String toString() => message;
}
