/// The credits and billing shapes the server sends (docs/api/billing.md).
///
/// Everything here is display data. The app never computes a price, a
/// balance or a limit: it shows these, and asks again when it needs to
/// know more.
library;

DateTime? _unix(Object? seconds) {
  final s = (seconds as num?)?.toInt() ?? 0;
  return s <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(s * 1000);
}

int _int(Object? v) => (v as num?)?.toInt() ?? 0;

/// GET /v1/billing/wallet.
class Wallet {
  const Wallet({
    required this.balance,
    required this.held,
    required this.available,
    required this.debt,
    this.expiringSoon = const [],
  });

  /// What a 503 (billing not reachable) reads as: nothing to show, and
  /// nothing to retry in a loop.
  static const empty = Wallet(balance: 0, held: 0, available: 0, debt: 0);

  final int balance;
  final int held;
  final int available;
  final int debt;
  final List<ExpiringCredits> expiringSoon;

  factory Wallet.fromJson(Map<String, dynamic> json) => Wallet(
    balance: _int(json['balance']),
    held: _int(json['held']),
    available: _int(json['available']),
    debt: _int(json['debt']),
    expiringSoon: [
      for (final e in (json['expiring_soon'] as List<dynamic>? ?? const []))
        ExpiringCredits.fromJson(e as Map<String, dynamic>),
    ],
  );
}

/// Credits that expire or decay in the next 14 days (welcome credits).
class ExpiringCredits {
  const ExpiringCredits({
    required this.kind,
    required this.remaining,
    this.expiresAt,
    this.nextDecayAt,
    this.nextDecayCredits = 0,
  });

  final String kind;
  final int remaining;
  final DateTime? expiresAt;
  final DateTime? nextDecayAt;
  final int nextDecayCredits;

  factory ExpiringCredits.fromJson(Map<String, dynamic> json) =>
      ExpiringCredits(
        kind: json['kind'] as String? ?? '',
        remaining: _int(json['remaining']),
        expiresAt: _unix(json['expires_at_unix_seconds']),
        nextDecayAt: _unix(json['next_decay_at_unix_seconds']),
        nextDecayCredits: _int(json['next_decay_credits']),
      );
}

/// One line of credit history.
class LedgerEntry {
  const LedgerEntry({
    required this.id,
    required this.delta,
    required this.reason,
    required this.refType,
    required this.balanceAfter,
    required this.createdAt,
  });

  final int id;
  final int delta;
  final String reason;
  final String refType;
  final int balanceAfter;
  final DateTime createdAt;

  factory LedgerEntry.fromJson(Map<String, dynamic> json) => LedgerEntry(
    id: _int(json['id']),
    delta: _int(json['delta']),
    reason: json['reason'] as String? ?? '',
    refType: json['ref_type'] as String? ?? '',
    balanceAfter: _int(json['balance_after']),
    createdAt:
        _unix(json['created_at_unix_seconds']) ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );

  /// Whether the history shows this line. A creation writes a hold and a
  /// capture, and a release undoes a hold; those move credits between
  /// "held" and "spent" without changing what the person has, so only the
  /// lines that change the balance are worth a row.
  bool get visible => delta != 0;

  /// The plain-language name of the change. The server's reasons are
  /// bookkeeping words; this is what a person reads.
  String get label => switch (reason) {
    'grant' when refType == 'welcome' => 'Welcome credits',
    'grant' when refType == 'store_purchase' => 'Purchased',
    'grant' => 'Credits added',
    'hold' || 'capture' => 'Meetup created',
    'release' => 'Meetup not created',
    'refund' => 'Refund',
    'decay' || 'expire' => 'Expired',
    'reversal' when refType == 'debt' => 'Owed credits paid off',
    'reversal' => 'Store refund',
    'admin_adjust' => 'Adjusted by TieHere',
    _ => 'Credits changed',
  };
}

/// One page of history, newest first.
class LedgerPage {
  const LedgerPage({required this.entries, this.nextCursor});

  static const empty = LedgerPage(entries: []);

  final List<LedgerEntry> entries;

  /// Null when there are no more pages.
  final String? nextCursor;

  factory LedgerPage.fromJson(Map<String, dynamic> json) {
    final next = json['next_cursor'] as String?;
    return LedgerPage(
      entries: [
        for (final e in (json['entries'] as List<dynamic>? ?? const []))
          LedgerEntry.fromJson(e as Map<String, dynamic>),
      ],
      nextCursor: (next == null || next.isEmpty) ? null : next,
    );
  }
}

/// How big and how far ahead the caller may schedule.
class CreationLimits {
  const CreationLimits({
    required this.maxCapacity,
    required this.maxAdvanceDays,
  });

  /// The free limits (D4), used when the server cannot be asked.
  static const fallback = CreationLimits(maxCapacity: 20, maxAdvanceDays: 14);

  final int maxCapacity;
  final int maxAdvanceDays;

  factory CreationLimits.fromJson(Map<String, dynamic>? json) {
    if (json == null) return fallback;
    final cap = _int(json['max_capacity']);
    final days = _int(json['max_advance_days']);
    return CreationLimits(
      maxCapacity: cap > 0 ? cap : fallback.maxCapacity,
      maxAdvanceDays: days > 0 ? days : fallback.maxAdvanceDays,
    );
  }
}

/// POST /v1/billing/quote.
class CreditQuote {
  const CreditQuote({
    required this.cost,
    required this.priceVersion,
    required this.coveredByPlan,
    required this.balanceAvailable,
    required this.limits,
  });

  /// What creating will charge (0 inside a plan's quota).
  final int cost;
  final int priceVersion;
  final bool coveredByPlan;
  final int balanceAvailable;
  final CreationLimits limits;

  /// The server's own numbers say whether there is enough. The app does
  /// no arithmetic on money beyond this comparison of two of them.
  bool get affordable => coveredByPlan || cost <= balanceAvailable;

  factory CreditQuote.fromJson(Map<String, dynamic> json) => CreditQuote(
    cost: _int(json['cost']),
    priceVersion: _int(json['price_version']),
    coveredByPlan: json['covered_by_plan'] as bool? ?? false,
    balanceAvailable: _int(json['balance_available']),
    limits: CreationLimits.fromJson(json['limits'] as Map<String, dynamic>?),
  );
}

/// GET /v1/billing/entitlements.
class Entitlements {
  const Entitlements({
    required this.limits,
    this.planCode = '',
    this.meetupsIncluded = 0,
    this.meetupsUsed = 0,
  });

  static const fallback = Entitlements(limits: CreationLimits.fallback);

  final CreationLimits limits;
  final String planCode;
  final int meetupsIncluded;
  final int meetupsUsed;

  factory Entitlements.fromJson(Map<String, dynamic> json) => Entitlements(
    limits: CreationLimits.fromJson(json['limits'] as Map<String, dynamic>?),
    planCode: json['plan_code'] as String? ?? '',
    meetupsIncluded: _int(json['meetups_included']),
    meetupsUsed: _int(json['meetups_used']),
  );
}

/// GET /v1/billing/catalog. No prices, by design: the store's price for
/// each product id is the only one the app shows.
class Catalog {
  const Catalog({
    required this.version,
    required this.creditPacks,
    required this.plansVisible,
    required this.plans,
    this.termsUrl = '',
    this.privacyUrl = '',
    this.appAccountToken = '',
  });

  /// Nothing on sale, plans hidden: what a 503 reads as.
  static const empty = Catalog(
    version: 0,
    creditPacks: [],
    plansVisible: false,
    plans: [],
  );

  final int version;
  final List<CreditPack> creditPacks;
  final bool plansVisible;
  final List<CatalogPlan> plans;
  final String termsUrl;
  final String privacyUrl;
  final String appAccountToken;

  factory Catalog.fromJson(Map<String, dynamic> json) {
    final legal = json['legal'] as Map<String, dynamic>? ?? const {};
    return Catalog(
      version: _int(json['catalog_version']),
      creditPacks: [
        for (final p in (json['credit_packs'] as List<dynamic>? ?? const []))
          CreditPack.fromJson(p as Map<String, dynamic>),
      ]..sort((a, b) => a.sort.compareTo(b.sort)),
      plansVisible: json['plans_visible'] as bool? ?? false,
      plans: [
        for (final p in (json['plans'] as List<dynamic>? ?? const []))
          CatalogPlan.fromJson(p as Map<String, dynamic>),
      ],
      termsUrl: legal['terms_url'] as String? ?? '',
      privacyUrl: legal['privacy_url'] as String? ?? '',
      appAccountToken: json['app_account_token'] as String? ?? '',
    );
  }
}

/// One credit pack. [credits] is everything it grants; [bonus] is the
/// part of that to show as a bonus.
class CreditPack {
  const CreditPack({
    required this.productId,
    required this.credits,
    this.bonus = 0,
    this.badge = '',
    this.sort = 0,
  });

  final String productId;
  final int credits;
  final int bonus;
  final String badge;
  final int sort;

  factory CreditPack.fromJson(Map<String, dynamic> json) => CreditPack(
    productId: json['product_id'] as String? ?? '',
    credits: _int(json['credits']),
    bonus: _int(json['bonus']),
    badge: json['badge'] as String? ?? '',
    sort: _int(json['sort']),
  );

  /// "Popular", "Best value": the badge's words, sentence case.
  String get badgeLabel => switch (badge) {
    'popular' => 'Popular',
    'best_value' => 'Best value',
    '' => '',
    _ => badge[0].toUpperCase() + badge.substring(1).replaceAll('_', ' '),
  };
}

/// One subscription product in the catalog.
class CatalogPlan {
  const CatalogPlan({
    required this.code,
    required this.productIds,
    required this.period,
    required this.title,
    this.perks = const [],
    this.featured = false,
  });

  final String code;

  /// Store product id per platform (`ios`, `android`).
  final Map<String, String> productIds;
  final String period;
  final String title;
  final List<String> perks;
  final bool featured;

  String productIdFor(String platform) => productIds[platform] ?? '';

  /// "Monthly", "Yearly".
  String get periodLabel => switch (period) {
    'month' => 'Monthly',
    'year' => 'Yearly',
    _ => title,
  };

  /// "Billed monthly".
  String get billingLabel => switch (period) {
    'month' => 'Billed monthly',
    'year' => 'Billed yearly',
    _ => '',
  };

  factory CatalogPlan.fromJson(Map<String, dynamic> json) => CatalogPlan(
    code: json['code'] as String? ?? '',
    productIds: {
      for (final e
          in (json['product_ids'] as Map<String, dynamic>? ?? const {}).entries)
        e.key: e.value as String,
    },
    period: json['period'] as String? ?? '',
    title: json['title'] as String? ?? '',
    perks: [
      for (final p in (json['perks'] as List<dynamic>? ?? const []))
        p as String,
    ],
    featured: json['featured'] as bool? ?? false,
  );
}

/// POST /v1/billing/purchases/verify, for a credit pack.
class PurchaseGrant {
  const PurchaseGrant({
    required this.productId,
    required this.creditsGranted,
    required this.alreadyProcessed,
    required this.wallet,
  });

  final String productId;
  final int creditsGranted;
  final bool alreadyProcessed;
  final Wallet wallet;

  factory PurchaseGrant.fromJson(Map<String, dynamic> json) => PurchaseGrant(
    productId: json['product_id'] as String? ?? '',
    creditsGranted: _int(json['credits_granted']),
    alreadyProcessed: json['already_processed'] as bool? ?? false,
    wallet: Wallet.fromJson(
      json['wallet'] as Map<String, dynamic>? ?? const {},
    ),
  );
}
