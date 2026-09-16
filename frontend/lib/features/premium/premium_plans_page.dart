import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';

/// The Premium plans screen, UI only (2026-09-16). The plans, prices and
/// perks below are placeholders until billing is wired: nothing here talks
/// to a store or the backend, and the call to action says so. The real
/// purchase flow (`premium_page.dart`, `PurchaseFlowController`) is kept
/// as it was for when that happens; this screen is what the app shows in
/// the meantime, so the design can be judged on a phone now.
///
/// Shape follows the reference: a headline, one brand-coloured card for
/// the featured plan with its perks listed inside a white inset, a
/// monthly/annual choice as two rows, and the one button at the bottom.
class PremiumPlansPage extends StatefulWidget {
  const PremiumPlansPage({super.key});

  @override
  State<PremiumPlansPage> createState() => _PremiumPlansPageState();
}

enum _Billing { monthly, annual }

class _PremiumPlansPageState extends State<PremiumPlansPage> {
  _Billing _billing = _Billing.annual;

  static const _perks = [
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
    (
      Icons.support_agent_rounded,
      '',
      'Priority help',
      ' from the TieHere team.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        leading: const SizedBox.shrink(),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _CloseButton(onTap: () => Navigator.of(context).pop()),
          ),
        ],
      ),
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                  children: [
                    Center(
                      child: Text(
                        'Try TieHere Premium free',
                        style: TextStyle(
                          color: AppPalette.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Center(
                      child: Text(
                        'Unlock all features',
                        style: TextStyle(
                          color: AppPalette.textPrimary,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    _FeaturedPlanCard(perks: _perks),
                    const SizedBox(height: 16),
                    _BillingRow(
                      label: 'Monthly',
                      price: 'Rs 1,490',
                      trailing: 'Billed monthly',
                      selected: _billing == _Billing.monthly,
                      onTap: () => setState(() => _billing = _Billing.monthly),
                    ),
                    const SizedBox(height: 10),
                    _BillingRow(
                      label: 'Annual',
                      price: 'Rs 12,900',
                      trailing: 'Popular',
                      trailingIsBadge: true,
                      selected: _billing == _Billing.annual,
                      onTap: () => setState(() => _billing = _Billing.annual),
                    ),
                    const SizedBox(height: 12),
                    Center(
                      child: Text(
                        'Cancel any time. Prices are placeholders until '
                        'billing goes live.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppPalette.textSecondary,
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 16 + bottomInset),
                child: PrimaryButton(
                  label: 'START 7 DAYS FREE TRIAL',
                  fillColor: AppPalette.brandGreen,
                  foregroundColor: Colors.white,
                  onPressed: () => showSnack(
                    context,
                    'Premium is coming soon. We will let you know the moment '
                    'it opens.',
                    type: ToastType.info,
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

/// The featured plan: the brand green, a faint dot texture, the monthly and
/// yearly figures, and the perks in a white inset card with a thin line
/// joining their icons, as in the reference.
class _FeaturedPlanCard extends StatelessWidget {
  const _FeaturedPlanCard({required this.perks});

  final List<(IconData, String, String, String)> perks;

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF148F52);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: green,
        boxShadow: [
          BoxShadow(
            color: green.withValues(alpha: AppPalette.isLight ? 0.28 : 0.45),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: CustomPaint(
        painter: const _DotTexture(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const _Price(amount: 'Rs 1,075', period: '/month', large: true),
                const Spacer(),
                const _Price(amount: 'Rs 12,900', period: '/year'),
              ],
            ),
            const SizedBox(height: 18),
            const Text(
              'Premium Annual Plan',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Everything TieHere has, for a full year, with two months free.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'This plan gets',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < perks.length; i++)
                    _PerkRow(perk: perks[i], last: i == perks.length - 1),
                ],
              ),
            ),
          ],
        ),
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
          color: Colors.white,
          fontSize: large ? 30 : 18,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
        ),
        children: [
          TextSpan(
            text: period,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
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
class _PerkRow extends StatelessWidget {
  const _PerkRow({required this.perk, required this.last});

  final (IconData, String, String, String) perk;
  final bool last;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF1B2A24);
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
                  border: Border.all(color: const Color(0xFFDDE5E1)),
                ),
                child: Icon(icon, size: 16, color: ink),
              ),
              if (!last)
                const Expanded(
                  child: SizedBox(
                    width: 1,
                    child: ColoredBox(color: Color(0xFFE6ECE9)),
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
                  style: const TextStyle(
                    color: ink,
                    fontSize: 13.5,
                    height: 1.35,
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
          ),
        ],
      ),
    );
  }
}

/// A row for one billing choice: a radio, the name and price, and either a
/// note or a small badge on the right. The chosen one takes a pale tint.
class _BillingRow extends StatelessWidget {
  const _BillingRow({
    required this.label,
    required this.price,
    required this.trailing,
    required this.selected,
    required this.onTap,
    this.trailingIsBadge = false,
  });

  final String label;
  final String price;
  final String trailing;
  final bool selected;
  final bool trailingIsBadge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tint = AppPalette.tintedSurface(
      AppPalette.brandGreen.withValues(alpha: 0.12),
    );
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        decoration: BoxDecoration(
          color: selected ? tint : AppPalette.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
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
                color: selected ? AppPalette.brandGreen : Colors.transparent,
                border: Border.all(
                  color: selected ? AppPalette.brandGreen : AppPalette.hairline,
                  width: 1.5,
                ),
              ),
              child: selected
                  ? const Icon(
                      Icons.check_rounded,
                      size: 14,
                      color: Colors.white,
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              price,
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const Spacer(),
            if (trailingIsBadge)
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
                  trailing,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )
            else
              Text(
                trailing,
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

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppPalette.card,
          border: Border.all(color: AppPalette.hairline),
        ),
        child: Icon(
          Icons.close_rounded,
          size: 20,
          color: AppPalette.textPrimary,
        ),
      ),
    );
  }
}

/// The reference's faint dot grid over the plan card's top-left, fading
/// out towards the right so the price stays clean.
class _DotTexture extends CustomPainter {
  const _DotTexture();

  @override
  void paint(Canvas canvas, Size size) {
    const spacing = 12.0;
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.12);
    for (var y = 0.0; y < size.height * 0.55; y += spacing) {
      for (var x = 0.0; x < size.width * 0.6; x += spacing) {
        final fade = 1 - (x / (size.width * 0.6));
        paint.color = Colors.white.withValues(alpha: 0.14 * fade);
        canvas.drawCircle(Offset(x, y), 1.1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotTexture oldDelegate) => false;
}
