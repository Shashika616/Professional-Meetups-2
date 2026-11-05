import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:professional_connections_platform/core/widgets/brand_loader.dart';
import 'package:professional_connections_platform/core/analytics/event_names.g.dart';
import 'package:professional_connections_platform/core/models/credits.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/client_info_http_client.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/utils/uuid.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/empty_section.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/load_failed_state.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';
import 'package:professional_connections_platform/features/credits/credits_format.dart';
import 'package:professional_connections_platform/features/premium/purchase_flow_controller.dart';
import 'package:professional_connections_platform/features/premium/purchase_listener.dart';

/// Buy credits (plan 29C): the packs the catalog lists, at the price the
/// store shows, bought through [PurchaseFlowController]'s consumable path.
///
/// Nothing here knows a price. The catalog says what a pack grants; the
/// store says what it costs, in the buyer's currency; a pack the store does
/// not return is simply not offered. The credits arrive only when the
/// server has verified the purchase, and the store transaction is finished
/// only after that.
///
/// Pops with `true` when a pack was bought, so the schedule flow knows to
/// price the meetup again.
class BuyCreditsPage extends ConsumerStatefulWidget {
  const BuyCreditsPage({
    super.key,
    this.platform,
    this.purchaseUpdates,
    this.buyConsumable,
    this.completePurchase,
  });

  /// `ios` or `android`; defaults to this device. Test seams, like the
  /// three below, which default to the real `InAppPurchase.instance`.
  final String? platform;
  final Stream<List<PurchaseDetails>>? purchaseUpdates;
  final Future<bool> Function(PurchaseParam)? buyConsumable;
  final Future<void> Function(PurchaseDetails)? completePurchase;

  @override
  ConsumerState<BuyCreditsPage> createState() => _BuyCreditsPageState();
}

class _BuyCreditsPageState extends ConsumerState<BuyCreditsPage> {
  late final PurchaseFlowController _controller;
  late final bool _ownsController;
  late final String _platform =
      widget.platform ?? ClientInfoHttpClient.currentPlatform();

  /// Store products by id; null while loading.
  Map<String, ProductDetails>? _products;
  Object? _storeError;
  int _loadedFor = -1;
  bool _bought = false;
  PurchaseGrant? _grant;

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
          creditService: ref.read(creditServiceProvider),
          platform: _platform,
          purchaseUpdates: widget.purchaseUpdates,
          buyConsumable: widget.buyConsumable,
          completePurchase: widget.completePurchase,
        );
    _controller
      ..addListener(_onControllerChanged)
      ..beginFlow(AnalyticsFlow.buyCredits);
  }

  Future<void> _loadProducts(Catalog catalog) async {
    _loadedFor = catalog.version;
    _controller.consumableIds = {
      for (final p in catalog.creditPacks) p.productId,
    };
    if (catalog.creditPacks.isEmpty) {
      setState(() => _products = const {});
      return;
    }
    try {
      final details = await ref
          .read(subscriptionServiceProvider)
          .availableProducts([
            for (final p in catalog.creditPacks) p.productId,
          ]);
      if (!mounted) return;
      setState(() {
        _products = {for (final d in details) d.id: d};
        _storeError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _storeError = e);
    }
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    final error = _controller.errorMessage;
    if (error != null) showSnack(context, error, type: ToastType.error);
    final grant = _controller.lastGrant;
    if (grant != null && !identical(grant, _grant)) {
      _grant = grant;
      _bought = true;
      ref.invalidate(walletProvider);
      showSnack(
        context,
        grant.alreadyProcessed
            ? 'That purchase was already added.'
            : '${formatCredits(grant.creditsGranted)} added.',
        type: ToastType.success,
      );
    }
  }

  @override
  void dispose() {
    _controller.endFlow();
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) _controller.dispose();
    super.dispose();
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
    if (catalog != null && catalog.version != _loadedFor) {
      // After this frame: setState inside build is not allowed.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && catalog.version != _loadedFor) _loadProducts(catalog);
      });
    }
    final wallet = ref.watch(walletProvider).value;
    final balance = _grant?.wallet.available ?? wallet?.available;

    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_bought);
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(title: const Text('Buy credits')),
        body: AppBackground(
          child: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              children: [
                _BalanceLine(
                  key: const Key('buyCreditsBalance'),
                  balance: balance,
                ),
                const SizedBox(height: 16),
                ..._packs(catalogAsync),
                const SizedBox(height: 16),
                Text(
                  'Prices are set by the App Store or Google Play. Bought credits never expire.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _packs(AsyncValue<Catalog> catalogAsync) {
    if (catalogAsync.hasError && !catalogAsync.hasValue) {
      return [
        LoadFailedState(
          compact: true,
          failure: LoadFailure.of(catalogAsync.error),
          onRetry: () => ref.invalidate(catalogProvider),
        ),
      ];
    }
    if (_storeError != null) {
      return [
        LoadFailedState(
          compact: true,
          failure: const LoadFailure(
            LoadFailureKind.server,
            'The store did not answer',
            'Credit packs could not be loaded from the store. Try again in a moment.',
          ),
          onRetry: () {
            final c = catalogAsync.value;
            if (c != null) _loadProducts(c);
          },
        ),
      ];
    }
    final catalog = catalogAsync.value;
    final products = _products;
    if (catalog == null || products == null) {
      return [
        for (var i = 0; i < 3; i++) ...[
          const SkeletonLoader(
            child: SkeletonBox(width: double.infinity, height: 72, radius: 16),
          ),
          const SizedBox(height: 10),
        ],
      ];
    }
    final onSale = [
      for (final p in catalog.creditPacks)
        if (products[p.productId] != null) p,
    ];
    if (onSale.isEmpty) {
      return const [
        EmptySection(
          key: Key('buyCreditsEmpty'),
          icon: AppIcons.credits,
          title: 'No credit packs here right now',
          message:
              'Credit packs come from the App Store or Google Play, and none are available on this device.',
        ),
      ];
    }
    return [
      for (final pack in onSale) ...[
        _PackRow(
          key: Key('pack-${pack.productId}'),
          pack: pack,
          product: products[pack.productId]!,
          enabled: !_controller.busy,
          onTap: () => _controller.buy(products[pack.productId]!),
        ),
        const SizedBox(height: 10),
      ],
      if (_controller.busy)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Center(child: BrandLoader(size: 28)),
        ),
    ];
  }
}

class _BalanceLine extends StatelessWidget {
  const _BalanceLine({super.key, required this.balance});

  final int? balance;

  @override
  Widget build(BuildContext context) {
    return FlatCard(
      radius: 18,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Row(
        children: [
          AppIcon(AppIcons.credits, size: 22, color: AppPalette.candyBlue),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Your balance',
              style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
            ),
          ),
          balance == null
              ? const SkeletonLoader(child: SkeletonBox(width: 70, height: 14))
              : Text(
                  formatCredits(balance!),
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
        ],
      ),
    );
  }
}

/// One pack: what it grants, its bonus and badge, and the store's price.
class _PackRow extends StatelessWidget {
  const _PackRow({
    super.key,
    required this.pack,
    required this.product,
    required this.enabled,
    required this.onTap,
  });

  final CreditPack pack;
  final ProductDetails product;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
          decoration: BoxDecoration(
            color: AppPalette.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppPalette.hairline),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          formatCredits(pack.credits),
                          style: TextStyle(
                            color: AppPalette.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (pack.badgeLabel.isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: AppPalette.hairline),
                            ),
                            child: Text(
                              pack.badgeLabel,
                              style: TextStyle(
                                color: AppPalette.textPrimary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (pack.bonus > 0) ...[
                      const SizedBox(height: 3),
                      Text(
                        'Includes ${formatCredits(pack.bonus)} bonus',
                        style: TextStyle(
                          color: AppPalette.verifiedText,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: AppPalette.candyBlue.withValues(
                    alpha: enabled ? 0.14 : 0.06,
                  ),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  product.price,
                  style: TextStyle(
                    color: AppPalette.candyBlue,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
