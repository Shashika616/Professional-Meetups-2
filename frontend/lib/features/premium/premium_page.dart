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
const List<(IconData, String, String, String)> premiumPerks = [
  (Icons.event_available_rounded, 'Host up to ', 'three meetups a day', '.'),
  (
    Icons.tune_rounded,
    'Filter Happening Soon by ',
    'company and industry',
    '.',
  ),
  (
    Icons.verified_user_rounded,
    'A ',
    'Premium mark',
    ' on your profile and cards.',
  ),
  (Icons.support_agent_rounded, '', 'Priority help', ' from the TieHere team.'),
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

    // The card shows the featured tier when the store has it, otherwise
    // whichever tier is selected, so a store with only one product still
    // gets the full treatment for that product.
    final featured = products == null
        ? null
        : (products[featuredTier] != null
              ? featuredTier
              : (_selected != null && products[_selected] != null
                    ? _selected
                    : null));

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
      appBar: AppBar(title: const Text('PREMIUM')),
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                  children: [
                    statusAsync.when(
                      data: (status) => _StatusCard(status: status),
                      loading: () => const SkeletonLoader(
                        child: SkeletonBox(width: double.infinity, height: 88),
                      ),
                      error: (_, _) => const SizedBox.shrink(),
                    ),
                    const SizedBox(height: 20),
                    Center(
                      child: Text(
                        entitled ? 'Your plan' : 'Unlock all features',
                        style: TextStyle(
                          color: AppPalette.textPrimary,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    // The card with the perks is always here: what Premium
                    // gets you does not depend on the store answering.
                    // Prices, tier rows and the button do, so they follow
                    // the store's reply below.
                    _FeaturedPlanCard(
                      tier: featured ?? featuredTier,
                      product: featured == null ? null : products?[featured],
                      isCurrent: featured != null && currentTier == featured,
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
                          'Restore Purchases',
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
                    label: entitled ? 'CURRENT PLAN' : 'SUBSCRIBE',
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

/// Where the account stands, from the backend. The one place on the screen
/// that says FREE / PREMIUM / ENTERPRISE.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});

  final SubscriptionStatus status;

  @override
  Widget build(BuildContext context) {
    final label = switch (status.tier) {
      SubscriptionTier.enterprise => 'ENTERPRISE',
      SubscriptionTier.premium when status.isEntitled => 'PREMIUM',
      _ => 'FREE',
    };
    final tier = PremiumTier.forProductId(status.productId);
    final subtitle = status.isEntitled
        ? [
            if (tier != null) '${tier.label} plan',
            if (status.currentPeriodEnd != null)
              'Renews ${_formatDate(status.currentPeriodEnd!)}'
            else
              'Active',
          ].join(' · ')
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

  static String _formatDate(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

/// The featured plan: the brand green, a faint dot texture, the store's
/// price and title for that tier, and the perks in a white inset card with
/// a thin line joining their icons.
class _FeaturedPlanCard extends StatelessWidget {
  const _FeaturedPlanCard({
    required this.tier,
    required this.product,
    required this.isCurrent,
  });

  final PremiumTier tier;

  /// Null while the store has not answered, or has nothing: the card then
  /// shows the perks under a generic title and no price at all, rather
  /// than a made-up one.
  final ProductDetails? product;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    // # WHY THIS IS NOT A GREEN SLAB ANY MORE
    //
    // It used to be the whole card: a full-bleed AppPalette.brandGreen fill
    // with a coloured glow under it, a white inset panel and white dot
    // texture. It was the one surface in the app that belonged to no palette
    // — every other card is the onyx/surface/card ramp with a hairline, and
    // the brand's blue/green only ever appears as a MARK (a verified tick,
    // the logo, a selected radio), never as a page-sized fill. At that size
    // the green stopped reading as the brand and started reading as a
    // sticker, and the white panel inside it glared out of an otherwise
    // near-black page.
    //
    // So the surface is the shared one now, and the green does what it does
    // everywhere else in the app: it marks. The hairline, the perk icons and
    // the CURRENT PLAN pill carry it; the type is the theme's own ink, which
    // is also what finally makes this card correct in light mode. The glow
    // is gone for the same reason ADR-032 removed every other one.
    final accent = AppPalette.brandGreen;
    // The tint has to be STRONGER on light, not equal. The dark page is
    // near-black, so a 5% green wash on a #181D24 card is already a visible
    // shift; the light page is #F3F6F9 with white cards, where that same 5%
    // lands between two near-whites and the card dissolves into the page.
    // One number for both themes would be "consistent" and would look
    // unfinished in one of them — the same reason FlatCard's own elevation
    // and SkeletonBox's tint each carry a per-theme value.
    final light = AppPalette.isLight;
    return FlatCard(
      radius: 20,
      // The one card on this screen meant to be read first — FlatCard lifts
      // it the way each theme actually reads (a real shadow on light, a
      // lighter surface on dark), instead of a coloured halo.
      elevated: true,
      tint: accent.withValues(alpha: light ? 0.14 : 0.05),
      border: accent.withValues(alpha: light ? 0.55 : 0.35),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: product == null
                    ? Text(
                        'TieHere Premium',
                        style: TextStyle(
                          color: AppPalette.textPrimary,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                        ),
                      )
                    : _Price(
                        amount: product!.price,
                        period: '/${tier.period}',
                        large: true,
                      ),
              ),
              if (isCurrent)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    // Tinted ONTO the card rather than laid over it at
                    // alpha — the house rule for accents on an opaque
                    // surface (AppPalette.tintedSurface's own comment).
                    color: AppPalette.tintedSurface(
                      accent.withValues(alpha: 0.18),
                    ),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: accent.withValues(alpha: 0.5)),
                  ),
                  child: Text(
                    'CURRENT PLAN',
                    style: TextStyle(
                      color: accent,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            product == null
                ? 'Everything TieHere has'
                : (product!.title.isEmpty
                      ? 'Premium ${tier.label} Plan'
                      : product!.title),
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (product != null && product!.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              product!.description,
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            'This plan gets',
            style: TextStyle(
              color: AppPalette.textSecondary,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
            decoration: BoxDecoration(
              // A step away from the card it sits on, in whichever direction
              // that theme reads as nearer: the plain white card colour
              // against the tinted ground on light, a lighter surface on
              // dark (FlatCard's own elevated cue).
              color: light
                  ? AppPalette.card
                  : AppPalette.tintedSurface(
                      AppPalette.textPrimary.withValues(alpha: 0.04),
                    ),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppPalette.hairline),
            ),
            child: Column(
              children: [
                for (var i = 0; i < premiumPerks.length; i++)
                  _PerkRow(
                    perk: premiumPerks[i],
                    last: i == premiumPerks.length - 1,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Price extends StatelessWidget {
  const _Price({
    required this.amount,
    required this.period,
    this.large = false,
  });

  final String amount;
  final String period;
  final bool large;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        text: amount,
        style: TextStyle(
          color: AppPalette.textPrimary,
          fontSize: large ? 30 : 18,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
        ),
        children: [
          TextSpan(
            text: period,
            style: TextStyle(
              color: AppPalette.textSecondary,
              fontSize: large ? 15 : 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// One perk: an outlined round icon, the sentence with its key phrase in
/// weight, and a hairline down to the next icon.
///
/// Its ink used to be fixed (dark on a hardcoded white inset, back when the
/// card was a green slab). It is themed now, like the rest of the app — the
/// icon is the one thing still carrying the brand green, which is the size
/// green is supposed to appear at.
class _PerkRow extends StatelessWidget {
  const _PerkRow({required this.perk, required this.last});

  final (IconData, String, String, String) perk;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final ink = AppPalette.textPrimary;
    final (icon, before, strong, after) = perk;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: AppPalette.hairline),
                ),
                child: Icon(icon, size: 16, color: AppPalette.brandGreen),
              ),
              if (!last)
                Expanded(
                  child: SizedBox(
                    width: 1,
                    child: ColoredBox(color: AppPalette.hairline),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(0, 6, 0, last ? 8 : 18),
              child: Text.rich(
                TextSpan(
                  text: before,
                  style: TextStyle(color: ink, fontSize: 13.5, height: 1.35),
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
        ? 'CURRENT PLAN'
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
                  ? const Icon(
                      Icons.check_rounded,
                      size: 14,
                      color: Colors.white,
                    )
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
