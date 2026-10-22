import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/subscription_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/app_tag.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';
import 'package:professional_connections_platform/features/premium/purchase_flow_controller.dart';

/// The three Premium subscription products, sold identically as StoreKit2
/// auto-renewable subscriptions (iOS) and Play Billing subscriptions
/// (Android). **Each ID must be configured identically in App Store Connect
/// and Google Play Console** before a real purchase can succeed. Monthly
/// has existed as a concept since ADR-031 Slice B; weekly and yearly were
/// added by Plan 20 Fix 3 (2026-09-18) and are a needs-Shashika's-action
/// item, same category as the App Store Connect API key and the Google
/// Play service account. Until a product is configured the store returns
/// nothing for it and the screen simply does not offer that tier.
const String premiumWeeklyProductId = 'premium_weekly';
const String premiumMonthlyProductId = 'premium_monthly';
const String premiumYearlyProductId = 'premium_yearly';

/// The tiers in display order, with the words the screen uses for each.
/// The price, title and description of a tier come from the store's
/// [ProductDetails]; nothing about money is written down in this file.
enum PremiumTier {
  weekly(premiumWeeklyProductId, 'Weekly', 'week', 'Billed weekly'),
  monthly(premiumMonthlyProductId, 'Monthly', 'month', 'Billed monthly'),
  yearly(premiumYearlyProductId, 'Yearly', 'year', 'Billed yearly');

  const PremiumTier(this.productId, this.label, this.period, this.billing);

  final String productId;
  final String label;
  final String period;
  final String billing;

  static PremiumTier? forProductId(String? id) {
    for (final tier in values) {
      if (tier.productId == id) return tier;
    }
    return null;
  }
}

/// The tier the card at the top shows off and the one pre-selected when the
/// store offers it: the longest commitment, which the card's "two months
/// free" framing was written for. A presentation choice, not purchase
/// logic; every tier buys through the same [PurchaseFlowController.buy].
const PremiumTier featuredTier = PremiumTier.yearly;

/// What Premium gets you. ONE list for all three tiers, on purpose: the
/// per-tier differentiation (if any) is a business decision Shashika has
/// not made yet, so this is a deliberate placeholder in the same spirit as
/// the price placeholder it replaces. Do not invent different perks per
/// tier here; when the decision lands, key this by [PremiumTier].
const List<(String, String, String, String)> premiumPerks = [
  (AppIcons.calendarCheck, 'Host up to ', 'three meetups a day', '.'),
  (AppIcons.filter, 'Filter Happening Soon by ', 'company and industry', '.'),
  (AppIcons.verifiedBadge, 'A ', 'Premium mark', ' on your profile and cards.'),
  (AppIcons.support, '', 'Priority help', ' from the TieHere team.'),
];

/// The Premium screen (ADR-031, Slice B; consolidated by Plan 20 Fix 3),
/// reached from `ProfilePage`'s PREFERENCES row whether or not the account
/// is already entitled: this screen renders both states itself.
///
/// The one Premium screen in the app. It has the plans design (a featured
/// card with the perks in a white inset, one row per tier, one button) on
/// the real data flow: products come from the store through
/// [SubscriptionService.availableProducts] in one call for all three ids,
/// purchases go through [PurchaseFlowController] (stream-driven, never
/// polling), and the account's standing is the backend-confirmed
/// [SubscriptionStatus] via [subscriptionStatusProvider], never anything
/// inferred from local purchase state.
///
/// Tiers the store does not return (not yet configured, or withdrawn) are
/// simply absent: the screen shows what is actually on sale rather than
/// failing over one missing product. With nothing on sale it says so.
class PremiumPage extends ConsumerStatefulWidget {
  const PremiumPage({super.key});

  @override
  ConsumerState<PremiumPage> createState() => _PremiumPageState();
}

class _PremiumPageState extends ConsumerState<PremiumPage> {
  late final PurchaseFlowController _controller;

  /// Store products keyed by tier, in display order; null while loading.
  Map<PremiumTier, ProductDetails>? _products;
  String? _loadError;
  PremiumTier? _selected;

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
      final details = await ref
          .read(subscriptionServiceProvider)
          .availableProducts([
            for (final tier in PremiumTier.values) tier.productId,
          ]);
      if (!mounted) return;
      final byTier = <PremiumTier, ProductDetails>{};
      for (final tier in PremiumTier.values) {
        for (final product in details) {
          if (product.id == tier.productId) {
            byTier[tier] = product;
            break;
          }
        }
      }
      setState(() {
        _products = byTier;
        _loadError = null;
        // Pre-select the featured tier when it is on sale, else the first
        // one that is; nothing when nothing is.
        _selected = byTier.containsKey(featuredTier)
            ? featuredTier
            : (byTier.isEmpty ? null : byTier.keys.first);
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
    final status = statusAsync.value;
    final entitled = status?.isEntitled ?? false;
    final currentTier = entitled
        ? PremiumTier.forProductId(status?.productId)
        : null;
    final products = _products;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    final selectedProduct = _selected == null ? null : products?[_selected!];
    final canBuy =
        !entitled &&
        !_controller.busy &&
        selectedProduct != null &&
        _loadError == null;

    return Scaffold(
      backgroundColor: Colors.transparent,
      // extendBodyBehindAppBar so AppBackground paints the app-bar strip
      // too — without it the (transparent) bar shows through to nothing and
      // sits as a flat band above the image. Same shape as
      // verification_checklist_page.dart's Scaffold.
      extendBodyBehindAppBar: true,
      // The ordinary pushed-page bar: title, and Flutter's own back button
      // on the left. This screen used to suppress that and put a custom
      // round X on the right instead — the only screen in the app that did,
      // so leaving is where nothing else puts it. Consistency wins over the
      // modal flavour a close button implies; this is a pushed route like
      // any other (profile_page.dart pushes it).
      appBar: AppBar(title: const Text('Premium')),
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                  children: [
                    // ONE card: where the account stands, what the page
                    // is offering, and what Premium gets you. These were
                    // three stacked blocks — a status card, a centred
                    // 24px headline, and a green-tinted plan card with a
                    // second card inset inside it — so the screen opened
                    // on three competing surfaces before a single price.
                    // The screen set draws one plain card holding all of
                    // it, and prices where prices belong: on the tiers.
                    statusAsync.when(
                      data: (status) => _PerksCard(status: status),
                      loading: () => const SkeletonLoader(
                        child: SkeletonBox(
                          width: double.infinity,
                          height: 260,
                          radius: 20,
                        ),
                      ),
                      error: (_, _) => const _PerksCard(status: null),
                    ),
                    const SizedBox(height: 16),
                    if (_loadError != null)
                      Text(
                        _loadError!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppPalette.danger,
                          fontSize: 12,
                        ),
                      )
                    else if (products == null)
                      const SkeletonLoader(
                        child: SkeletonBox(
                          width: double.infinity,
                          height: 132,
                          radius: 16,
                        ),
                      )
                    else if (products.isEmpty)
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
                      for (final tier in PremiumTier.values)
                        if (products[tier] != null) ...[
                          _TierRow(
                            key: Key('tier-${tier.productId}'),
                            tier: tier,
                            product: products[tier]!,
                            selected: _selected == tier,
                            isCurrent: currentTier == tier,
                            featured: tier == featuredTier,
                            onTap: entitled
                                ? null
                                : () => setState(() => _selected = tier),
                          ),
                          const SizedBox(height: 10),
                        ],
                      const SizedBox(height: 2),
                      Center(
                        child: Text(
                          entitled
                              ? 'Manage or cancel your subscription from your '
                                    'app store account.'
                              : 'Cancel any time from your app store account.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppPalette.textSecondary,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Center(
                      child: TextButton(
                        onPressed: _controller.busy
                            ? null
                            : () => _controller.restore(),
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
              if (products != null && products.isNotEmpty)
                Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 16 + bottomInset),
                  // PrimaryButton's own default fill, not a green override:
                  // the app has exactly one primary-CTA colour and this page
                  // was the only screen opting out of it. Green stays on
                  // this page as a MARK (the card's hairline, the perk
                  // icons, the selected tier's tick); at full width it read
                  // as a different app's button.
                  child: PrimaryButton(
                    key: const Key('premiumSubscribe'),
                    label: entitled ? 'Current plan' : 'Subscribe',
                    isLoading: _controller.busy,
                    onPressed: canBuy
                        ? () => _controller.buy(selectedProduct)
                        : null,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What Premium gets you, with the account's standing as a tag at the top
/// — the shape the screen set draws: a `Free` chip, the page's one
/// headline, and the perks as check lines.
///
/// # NO GREEN SLAB, NO CARD INSIDE A CARD
///
/// This card used to be a green-tinted, green-bordered, elevated surface
/// with a second bordered panel inset inside it, the perks in that panel,
/// each with an outlined circle icon joined by a vertical hairline. Four
/// surfaces deep for a list of four sentences, and the only page in the
/// app with a colour-washed card. It is the ordinary card now, and the
/// green appears where it appears everywhere else: at glyph size.
class _PerksCard extends StatelessWidget {
  const _PerksCard({required this.status});

  /// Null when the backend has not answered — the perks are a fact about
  /// the product, so they are shown regardless, under the Free chip that
  /// an unconfirmed account is treated as anyway.
  final SubscriptionStatus? status;

  @override
  Widget build(BuildContext context) {
    final entitled = status?.isEntitled ?? false;
    final label = switch (status?.tier) {
      SubscriptionTier.enterprise => 'Enterprise',
      SubscriptionTier.premium when entitled => 'Premium',
      _ => 'Free',
    };
    final tier = PremiumTier.forProductId(status?.productId);
    final renewal = !entitled
        ? null
        : [
            if (tier != null) '${tier.label} plan',
            if (status?.currentPeriodEnd != null)
              'Renews ${_formatDate(status!.currentPeriodEnd!)}',
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
          for (final perk in premiumPerks) _PerkRow(perk: perk),
        ],
      ),
    );
  }

  static String _formatDate(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

/// One perk: an outlined round icon, the sentence with its key phrase in
/// weight, and a hairline down to the next icon.
///
/// Its ink used to be fixed (dark on a hardcoded white inset, back when the
/// card was a green slab). It is themed now, like the rest of the app — the
/// icon is the one thing still carrying the brand green, which is the size
/// green is supposed to appear at.
class _PerkRow extends StatelessWidget {
  const _PerkRow({required this.perk});

  final (String, String, String, String) perk;

  @override
  Widget build(BuildContext context) {
    final (icon, before, strong, after) = perk;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A tick at glyph size, not an outlined circle with a hairline
          // running down to the next one. The connector drew a process —
          // four steps in an order — where this is four unordered facts.
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: AppIcon(icon, size: 17, color: AppPalette.brandGreen),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Text.rich(
              TextSpan(
                text: before,
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 13.5,
                  height: 1.4,
                ),
                children: [
                  TextSpan(
                    text: strong,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(text: after),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A row for one tier: a radio, the name and the store's price, and on the
/// right either the billing note, a "Popular" badge for the featured tier,
/// or CURRENT PLAN for the one the account holds. The chosen one takes a
/// pale tint. Not tappable while the account is entitled: a subscriber
/// changes plan through the store, not by buying a second subscription.
class _TierRow extends StatelessWidget {
  const _TierRow({
    super.key,
    required this.tier,
    required this.product,
    required this.selected,
    required this.isCurrent,
    required this.featured,
    required this.onTap,
  });

  final PremiumTier tier;
  final ProductDetails product;
  final bool selected;
  final bool isCurrent;
  final bool featured;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tint = AppPalette.tintedSurface(
      AppPalette.brandGreen.withValues(alpha: 0.12),
    );
    final highlighted = selected || isCurrent;
    final badge = isCurrent
        ? 'Current plan'
        : featured
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
              tier.label,
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
                tier.billing,
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
