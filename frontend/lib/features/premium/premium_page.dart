import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:url_launcher/url_launcher.dart';

import 'package:professional_connections_platform/core/analytics/analytics.dart';
import 'package:professional_connections_platform/core/analytics/event_names.g.dart';
import 'package:professional_connections_platform/core/models/credits.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/client_info_http_client.dart';
import 'package:professional_connections_platform/core/services/subscription_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/utils/uuid.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/app_tag.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/load_failed_state.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';
import 'package:professional_connections_platform/features/premium/purchase_flow_controller.dart';
import 'package:professional_connections_platform/features/premium/purchase_listener.dart';

/// The Premium screen (ADR-031, Slice B; server-driven since plan 29C),
/// reached from `ProfilePage`'s Preferences row.
///
/// # THE SERVER SAYS WHAT IS ON OFFER, THE STORE SAYS WHAT IT COSTS
///
/// Plans, their titles, perks, which one is featured, and the legal links
/// come from the catalog (`GET /v1/billing/catalog`). Prices come from the
/// store's own [ProductDetails], in the buyer's currency; the catalog never
/// carries one. Nothing about the plans is written in this file, so:
///
/// - turning `billing.plans.visible` on shows the plans to a running app
///   (the catalog is fetched again each time this page opens and when the
///   app returns to the foreground), with no update;
/// - a product is withdrawn by the catalog (weekly was), not by code;
/// - a product the store does not return is simply not offered.
///
/// Purchases go through [PurchaseFlowController] (the store transaction is
/// completed only after the server confirms), carrying the account token as
/// `applicationUserName`. The account's standing is the server's
/// [SubscriptionStatus], never inferred from local purchase state.
class PremiumPage extends ConsumerStatefulWidget {
  const PremiumPage({
    super.key,
    this.platform,
    this.purchaseUpdates,
    this.buyNonConsumable,
    this.completePurchase,
  });

  /// Test seams; null means this device and the real `InAppPurchase`.
  final String? platform;
  final Stream<List<PurchaseDetails>>? purchaseUpdates;
  final Future<bool> Function(PurchaseParam)? buyNonConsumable;
  final Future<void> Function(PurchaseDetails)? completePurchase;

  @override
  ConsumerState<PremiumPage> createState() => _PremiumPageState();
}

class _PremiumPageState extends ConsumerState<PremiumPage> {
  late final PurchaseFlowController _controller;
  late final bool _ownsController;
  late final String _platform =
      widget.platform ?? ClientInfoHttpClient.currentPlatform();

  /// Store products by id; null while loading.
  Map<String, ProductDetails>? _products;
  String? _loadError;

  /// The product ids [_products] was loaded for, to reload when the
  /// catalog changes.
  String _loadedFor = '';
  String? _selected;

  @override
  void initState() {
    super.initState();
    // The app's one listener (N1-D2); a test seam builds its own.
    final shared = widget.purchaseUpdates == null
        ? ref.read(purchaseFlowProvider)
        : null;
    _ownsController = shared == null;
    _controller =
        shared ??
        PurchaseFlowController(
          subscriptionService: ref.read(subscriptionServiceProvider),
          platform: _platform,
          purchaseUpdates: widget.purchaseUpdates,
          buyNonConsumable: widget.buyNonConsumable,
          completePurchase: widget.completePurchase,
        );
    _controller
      ..addListener(_onControllerChanged)
      ..beginFlow(AnalyticsFlow.subscribe);
  }

  /// The plans on offer, for this platform, in catalog order.
  List<CatalogPlan> _offered(Catalog catalog) => [
    if (catalog.plansVisible)
      for (final p in catalog.plans)
        if (p.productIdFor(_platform).isNotEmpty) p,
  ];

  Future<void> _loadProducts(List<CatalogPlan> plans, String key) async {
    _loadedFor = key;
    if (plans.isEmpty) {
      setState(() => _products = const {});
      return;
    }
    try {
      final details = await ref
          .read(subscriptionServiceProvider)
          .availableProducts([
            for (final p in plans) p.productIdFor(_platform),
          ]);
      if (!mounted) return;
      final byId = {for (final d in details) d.id: d};
      setState(() {
        _products = byId;
        _loadError = null;
        // The featured plan when the store sells it, else the first it does.
        final onSale = [
          for (final p in plans)
            if (byId.containsKey(p.productIdFor(_platform))) p,
        ];
        final featured = onSale.where((p) => p.featured);
        _selected = onSale.isEmpty
            ? null
            : (featured.isNotEmpty ? featured.first : onSale.first)
                  .productIdFor(_platform);
      });
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _loadError = 'Could not load subscription options right now.',
      );
    }
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    final error = _controller.errorMessage;
    if (error != null) {
      showSnack(context, error, type: ToastType.error);
    }
    if (_controller.lastVerifiedStatus != null) {
      // The backend is the source of truth for "am I Premium now"; this
      // tells the rest of the app to read it again.
      ref.invalidate(subscriptionStatusProvider);
    }
  }

  @override
  void dispose() {
    _controller.endFlow();
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    // The account token comes from the session, which may resolve after
    // this page opens; a purchase is refused until it has.
    final userId = ref.watch(
      authSessionProvider.select((s) => s.value?.profile?.id),
    );
    _controller.accountToken = userId == null ? null : accountToken(userId);
    final catalogAsync = ref.watch(catalogProvider);
    final catalog = catalogAsync.value;
    final plans = catalog == null ? const <CatalogPlan>[] : _offered(catalog);
    if (catalog != null) {
      final key = [
        catalog.version,
        for (final p in plans) p.productIdFor(_platform),
      ].join(',');
      if (key != _loadedFor) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && key != _loadedFor) _loadProducts(plans, key);
        });
      }
    }

    final statusAsync = ref.watch(subscriptionStatusProvider);
    final status = statusAsync.value;
    final entitled = status?.isEntitled ?? false;
    final products = _products;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    final onSale = [
      for (final p in plans)
        if (products?[p.productIdFor(_platform)] != null) p,
    ];
    final selectedProduct = _selected == null ? null : products?[_selected!];
    final canBuy =
        !entitled &&
        !_controller.busy &&
        selectedProduct != null &&
        _loadError == null;
    // One plan today, so one list of perks; the first plan on offer says
    // what Premium gets you.
    final perks = plans.isEmpty ? const <String>[] : plans.first.perks;
    final hidden = catalog != null && !catalog.plansVisible;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(title: const Text('Premium')),
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                  children: [
                    statusAsync.when(
                      data: (status) => _PerksCard(
                        status: status,
                        perks: perks,
                        currentPlan: _planFor(plans, status.productId),
                      ),
                      loading: () => const SkeletonLoader(
                        child: SkeletonBox(
                          width: double.infinity,
                          height: 200,
                          radius: 20,
                        ),
                      ),
                      error: (_, _) => _PerksCard(
                        status: null,
                        perks: perks,
                        currentPlan: null,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (catalogAsync.hasError && catalog == null)
                      LoadFailedState(
                        compact: true,
                        failure: LoadFailure.of(catalogAsync.error),
                        onRetry: () => ref.invalidate(catalogProvider),
                      )
                    else if (hidden)
                      Text(
                        key: const Key('premiumHidden'),
                        'Premium plans are not available yet.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppPalette.textSecondary,
                          fontSize: 12.5,
                        ),
                      )
                    else if (_loadError != null)
                      Text(
                        _loadError!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppPalette.danger,
                          fontSize: 12,
                        ),
                      )
                    else if (catalog == null || products == null)
                      const SkeletonLoader(
                        child: SkeletonBox(
                          width: double.infinity,
                          height: 132,
                          radius: 16,
                        ),
                      )
                    else if (onSale.isEmpty)
                      Text(
                        'Plans and prices come from the App Store or Google '
                        'Play, and Premium isn\'t available on this device '
                        'right now.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppPalette.textSecondary,
                          fontSize: 12,
                        ),
                      )
                    else ...[
                      for (final plan in onSale) ...[
                        _TierRow(
                          key: Key('tier-${plan.productIdFor(_platform)}'),
                          plan: plan,
                          product: products[plan.productIdFor(_platform)]!,
                          selected: _selected == plan.productIdFor(_platform),
                          isCurrent:
                              entitled &&
                              status?.productId == plan.productIdFor(_platform),
                          onTap: entitled
                              ? null
                              : () => setState(
                                  () =>
                                      _selected = plan.productIdFor(_platform),
                                ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      const SizedBox(height: 2),
                      Center(
                        child: Text(
                          entitled
                              ? 'Manage or cancel your subscription from your '
                                    'app store account.'
                              : 'Renews automatically. Cancel any time from '
                                    'your app store account.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppPalette.textSecondary,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                    ],
                    if (catalog != null &&
                        (catalog.termsUrl.isNotEmpty ||
                            catalog.privacyUrl.isNotEmpty)) ...[
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (catalog.termsUrl.isNotEmpty)
                            TextButton(
                              key: const Key('premiumTerms'),
                              onPressed: () => _open(catalog.termsUrl),
                              child: Text(
                                'Terms of use',
                                style: TextStyle(
                                  color: AppPalette.candyBlue,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          if (catalog.privacyUrl.isNotEmpty)
                            TextButton(
                              key: const Key('premiumPrivacy'),
                              onPressed: () => _open(catalog.privacyUrl),
                              child: Text(
                                'Privacy policy',
                                style: TextStyle(
                                  color: AppPalette.candyBlue,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                    Center(
                      child: TextButton(
                        onPressed: _controller.busy
                            ? null
                            : () {
                                track(Cta.restorePurchases);
                                _controller.restore();
                              },
                        child: Text(
                          'Restore purchases',
                          style: TextStyle(
                            color: AppPalette.candyBlue,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (onSale.isNotEmpty && !hidden)
                Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 16 + bottomInset),
                  child: PrimaryButton(
                    key: const Key('premiumSubscribe'),
                    label: entitled ? 'Current plan' : 'Subscribe',
                    isLoading: _controller.busy,
                    onPressed: canBuy
                        ? () {
                            track(Cta.subscribe);
                            _controller.buy(selectedProduct);
                          }
                        : null,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  CatalogPlan? _planFor(List<CatalogPlan> plans, String? productId) {
    for (final p in plans) {
      if (p.productIdFor(_platform) == productId) return p;
    }
    return null;
  }
}

/// What Premium gets you, with the account's standing as a tag at the top.
/// One plain card; the perks are the catalog's.
class _PerksCard extends StatelessWidget {
  const _PerksCard({
    required this.status,
    required this.perks,
    required this.currentPlan,
  });

  /// Null when the backend has not answered.
  final SubscriptionStatus? status;
  final List<String> perks;

  /// The catalog plan the account holds, when the server names it.
  final CatalogPlan? currentPlan;

  @override
  Widget build(BuildContext context) {
    final entitled = status?.isEntitled ?? false;
    final label = switch (status?.tier) {
      SubscriptionTier.enterprise => 'Enterprise',
      SubscriptionTier.premium when entitled => 'Premium',
      _ => 'Free',
    };
    final renewal = !entitled
        ? null
        : [
            if (currentPlan != null) '${currentPlan!.periodLabel} plan',
            if (status?.currentPeriodEnd != null)
              '${status!.autoRenewStatus ? 'Renews' : 'Ends'} '
                  '${_formatDate(status!.currentPeriodEnd!)}',
          ].join(' · ');

    return FlatCard(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: AppTag(
              label,
              tone: entitled ? AppTone.success : AppTone.neutral,
              icon: entitled ? AppIcons.premium : null,
              compact: true,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            entitled ? 'Your plan' : 'Unlock all features',
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 19,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2,
            ),
          ),
          if (renewal != null && renewal.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              renewal,
              style: TextStyle(color: AppPalette.textSecondary, fontSize: 12.5),
            ),
          ],
          const SizedBox(height: 14),
          for (final perk in perks) _PerkRow(text: perk),
          if (perks.isEmpty) const SizedBox(height: 6),
        ],
      ),
    );
  }

  static String _formatDate(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

/// One perk: a tick at glyph size and the catalog's sentence.
class _PerkRow extends StatelessWidget {
  const _PerkRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: AppIcon(
              AppIcons.checkCircle,
              size: 17,
              color: AppPalette.brandGreen,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 13.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A row for one plan: a radio, the period and the store's price, and on
/// the right the billing note, "Popular" for the featured plan, or
/// "Current plan" for the one held. Not tappable while entitled: a
/// subscriber changes plan through the store.
class _TierRow extends StatelessWidget {
  const _TierRow({
    super.key,
    required this.plan,
    required this.product,
    required this.selected,
    required this.isCurrent,
    required this.onTap,
  });

  final CatalogPlan plan;
  final ProductDetails product;
  final bool selected;
  final bool isCurrent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tint = AppPalette.tintedSurface(
      AppPalette.brandGreen.withValues(alpha: 0.12),
    );
    final highlighted = selected || isCurrent;
    final badge = isCurrent
        ? 'Current plan'
        : plan.featured
        ? 'Popular'
        : null;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        decoration: BoxDecoration(
          color: highlighted ? tint : AppPalette.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: highlighted
                ? AppPalette.brandGreen.withValues(alpha: 0.5)
                : AppPalette.hairline,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: highlighted ? AppPalette.brandGreen : Colors.transparent,
                border: Border.all(
                  color: highlighted
                      ? AppPalette.brandGreen
                      : AppPalette.hairline,
                  width: 1.5,
                ),
              ),
              child: highlighted
                  ? const AppIcon(AppIcons.check, size: 14, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 12),
            Text(
              plan.periodLabel,
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                product.price,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (badge != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: AppPalette.card,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: AppPalette.hairline),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )
            else
              Text(
                plan.billingLabel,
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 12.5,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
