import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/subscription_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/section_label.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/features/premium/purchase_flow_controller.dart';

/// The one Premium subscription product this slice sells — a monthly
/// auto-renewing subscription, sold identically as a StoreKit2
/// auto-renewable subscription (iOS) and a Play Billing subscription
/// (Android). **This ID must be configured identically in App Store
/// Connect and Google Play Console** before a real purchase can succeed —
/// one of this round's "needs Shashika's action" items (see the backend
/// service's own report), same category as the App Store Connect API key
/// and Google Play service account.
const String premiumMonthlyProductId = 'premium_monthly';

/// Premium purchase flow UI (ADR-031, Slice B) — reached from
/// `ProfilePage`'s PREFERENCES section. Stream-driven via
/// [PurchaseFlowController] (never polls); shows the backend-confirmed
/// [SubscriptionStatus] via [subscriptionStatusProvider], never anything
/// derived from local purchase-stream state on its own.
class PremiumPage extends ConsumerStatefulWidget {
  const PremiumPage({super.key});

  @override
  ConsumerState<PremiumPage> createState() => _PremiumPageState();
}

class _PremiumPageState extends ConsumerState<PremiumPage> {
  late final PurchaseFlowController _controller;
  List<ProductDetails>? _products;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _controller = PurchaseFlowController(
      subscriptionService: ref.read(subscriptionServiceProvider),
      platform: defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
    )..addListener(_onControllerChanged);
    _loadProducts();
  }

  Future<void> _loadProducts() async {
    try {
      final products = await ref
          .read(subscriptionServiceProvider)
          .availableProducts([premiumMonthlyProductId]);
      if (!mounted) return;
      setState(() {
        _products = products;
        _loadError = null;
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
      // The backend is the source of truth for "am I Premium now" — this
      // just tells the rest of the app to re-read it, it never sets local
      // state that the UI would show instead.
      ref.invalidate(subscriptionStatusProvider);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final statusAsync = ref.watch(subscriptionStatusProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('PREMIUM')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
          children: [
            statusAsync.when(
              data: (status) => _statusCard(status),
              loading: () =>
                  const SkeletonBox(width: double.infinity, height: 88),
              error: (_, _) => const SizedBox.shrink(),
            ),
            const SizedBox(height: 24),
            SectionLabel('PLANS'),
            const SizedBox(height: 12),
            if (_loadError != null)
              Text(
                _loadError!,
                style: TextStyle(color: AppPalette.danger, fontSize: 12),
              )
            else if (_products == null)
              const SkeletonBox(width: double.infinity, height: 96)
            else if (_products!.isEmpty)
              Text(
                'Premium isn\'t available on this device right now.',
                style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
              )
            else
              for (final product in _products!) ...[
                _productCard(
                  product,
                  entitled: statusAsync.value?.isEntitled ?? false,
                ),
                const SizedBox(height: 12),
              ],
            const SizedBox(height: 20),
            Center(
              child: TextButton(
                onPressed: _controller.busy
                    ? null
                    : () => _controller.restore(),
                child: Text(
                  'Restore Purchases',
                  style: TextStyle(color: AppPalette.candyBlue, fontSize: 13),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusCard(SubscriptionStatus status) {
    final label = switch (status.tier) {
      SubscriptionTier.enterprise => 'ENTERPRISE',
      SubscriptionTier.premium when status.isEntitled => 'PREMIUM',
      _ => 'FREE',
    };
    final subtitle = status.isEntitled
        ? (status.currentPeriodEnd != null
              ? 'Renews ${_formatDate(status.currentPeriodEnd!)}'
              : 'Active')
        : 'Upgrade to unlock Premium features';
    return FlatCard(
      radius: 12,
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Icon(
            Icons.workspace_premium_rounded,
            color: AppPalette.gold,
            size: 30,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _productCard(ProductDetails product, {required bool entitled}) {
    return FlatCard(
      radius: 12,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            product.title,
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            product.description,
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            product.price,
            style: TextStyle(
              color: AppPalette.gold,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          PrimaryButton(
            label: entitled ? 'CURRENT PLAN' : 'SUBSCRIBE',
            isLoading: _controller.busy,
            onPressed: entitled || _controller.busy
                ? null
                : () => _controller.buy(product),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}
