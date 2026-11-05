part of 'schedule_flow.dart';

class _CapacityStep extends StatefulWidget {
  const _CapacityStep({
    required this.initial,
    required this.max,
    required this.onSubmit,
  });

  final int initial;

  /// The host's limit from entitlements: 20 free, 30 with a plan.
  final int max;
  final void Function(int capacity) onSubmit;

  @override
  State<_CapacityStep> createState() => _CapacityStepState();
}

class _CapacityStepState extends State<_CapacityStep> {
  late int _capacity = widget.initial;

  static const _min = 1;
  int get _max => widget.max;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StepTitle('How many people?'),
        const StepHero(asset: 'assets/images/schedule/capacity_card.jpg'),
        const SizedBox(height: 14),
        FlatCard(
          radius: 18,
          padding: const EdgeInsets.symmetric(vertical: 22),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _StepperButton(
                icon: AppIcons.minus,
                onTap: _capacity > _min
                    ? () => setState(() => _capacity--)
                    : null,
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$_capacity',
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                      color: AppPalette.textPrimary,
                      height: 1.0,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _capacity == 1 ? 'Just you' : 'People · including you',
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
              _StepperButton(
                icon: AppIcons.plus,
                onTap: _capacity < _max
                    ? () => setState(() => _capacity++)
                    : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        PrimaryButton(
          label: 'Continue',
          onPressed: () => widget.onSubmit(_capacity),
        ),
      ],
    );
  }
}

class _StepperButton extends StatelessWidget {
  const _StepperButton({required this.icon, required this.onTap});

  final String icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: enabled
              ? AppPalette.tintedSurface(
                  AppPalette.candyBlue.withValues(alpha: 0.15),
                )
              : AppPalette.tintedSurface(
                  AppPalette.textPrimary.withValues(alpha: 0.05),
                ),
        ),
        child: AppIcon(
          icon,
          color: enabled ? AppPalette.candyBlue : AppPalette.textSecondary,
        ),
      ),
    );
  }
}

class _ReviewStep extends StatelessWidget {
  const _ReviewStep({
    required this.intent,
    required this.windowStart,
    required this.windowEnd,
    required this.locationLabel,
    required this.capacity,
    required this.submitting,
    required this.quote,
    required this.quoting,
    required this.quoteFailed,
    required this.notice,
    required this.blockedByDebt,
    required this.onRetryQuote,
    required this.onBuyCredits,
    required this.onConfirm,
  });

  final IntentType intent;
  final DateTime windowStart;
  final DateTime windowEnd;
  final String locationLabel;
  final int capacity;
  final bool submitting;

  /// The server's price for this draft (plan 29C). Credits have no flag,
  /// so the cost row always shows.
  final CreditQuote? quote;
  final bool quoting;
  final bool quoteFailed;
  final String? notice;
  final bool blockedByDebt;
  final VoidCallback onRetryQuote;
  final VoidCallback onBuyCredits;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final crossesMidnight =
        windowEnd.year != windowStart.year ||
        windowEnd.month != windowStart.month ||
        windowEnd.day != windowStart.day;
    final placeLabel = locationLabel.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StepTitle('Review & confirm'),
        const StepHero(asset: 'assets/images/schedule/review_card.jpg'),
        const SizedBox(height: 14),
        FlatCard(
          radius: 18,
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ReviewRow(
                icon: intent.iconPath,
                label: 'Intent',
                value: intent.labelFor(windowStart),
                detail: intent.tagline,
              ),
              const _ReviewDivider(),
              _ReviewRow(
                icon: AppIcons.clock,
                label: 'When',
                // formatMeetupWindow renders a midnight-crossing window as
                // e.g. "10:00 PM–1:00 AM" with no day marker — fine on a
                // card, but this is the last look before it is created, so
                // the next-day case gets its own line.
                value: formatMeetupWindow(windowStart, windowEnd),
                detail: crossesMidnight
                    ? 'Ends the next day, '
                          '${formatTime24h(TimeOfDay.fromDateTime(windowEnd))}'
                    : null,
              ),
              const _ReviewDivider(),
              _ReviewRow(
                icon: placeLabel.isEmpty ? AppIcons.locate : AppIcons.pin,
                label: 'Location',
                // An empty label is the "use my current location" path
                // (ADR-029): coordinates are set, the address is resolved
                // server-side on creation. Say that rather than render a
                // blank row that looks like a bug.
                value: placeLabel.isEmpty
                    ? 'Your current location'
                    : placeLabel,
                detail: placeLabel.isEmpty
                    ? 'Address is filled in automatically when you schedule'
                    : null,
              ),
              const _ReviewDivider(),
              _ReviewRow(
                icon: AppIcons.people,
                label: 'Capacity',
                value: capacity == 1 ? '1 person' : '$capacity people',
                detail: 'Including you',
              ),
              const _ReviewDivider(),
              _costRow(),
            ],
          ),
        ),
        if (notice != null) ...[
          const SizedBox(height: 12),
          Text(
            notice!,
            key: const Key('reviewCostNotice'),
            textAlign: TextAlign.center,
            style: TextStyle(color: AppPalette.danger, fontSize: 12.5),
          ),
        ],
        const SizedBox(height: 20),
        _button(),
        const SizedBox(height: 24),
      ],
    );
  }
}

extension on _ReviewStep {
  /// The cost as the server quoted it, and the balance under it.
  Widget _costRow() {
    final q = quote;
    if (q == null) {
      return _ReviewRow(
        key: const Key('reviewCost'),
        icon: AppIcons.credits,
        label: 'Cost',
        value: quoteFailed ? 'Could not get the price' : 'Getting the price…',
        detail: quoteFailed ? 'Check your connection and try again' : null,
      );
    }
    return _ReviewRow(
      key: const Key('reviewCost'),
      icon: AppIcons.credits,
      label: 'Cost',
      value: q.coveredByPlan ? 'Included in your plan' : formatCredits(q.cost),
      detail: 'Your balance: ${formatCredits(q.balanceAvailable)}',
    );
  }

  /// CONFIRM, or what has to happen first: get the price, or buy credits.
  Widget _button() {
    final q = quote;
    if (q == null) {
      return PrimaryButton(
        key: const Key('reviewConfirm'),
        label: quoteFailed ? 'Try again' : 'Confirm & schedule',
        icon: quoteFailed ? AppIcons.refresh : null,
        isLoading: quoting,
        onPressed: quoteFailed ? onRetryQuote : null,
      );
    }
    if (blockedByDebt || !q.affordable) {
      return PrimaryButton(
        key: const Key('reviewConfirm'),
        label: 'Buy credits',
        isLoading: quoting,
        onPressed: quoting ? null : onBuyCredits,
      );
    }
    return PrimaryButton(
      key: const Key('reviewConfirm'),
      label: 'Confirm & schedule',
      isLoading: submitting || quoting,
      onPressed: quoting ? null : onConfirm,
    );
  }
}

/// One line of the review card: a small-caps label, the value under it in
/// the reading colour, and an optional secondary line. Stacked rather than
/// label-left/value-right so long values (an address, a window that ends
/// tomorrow) wrap as a paragraph instead of ragged-right against the label.
class _ReviewRow extends StatelessWidget {
  const _ReviewRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.detail,
  });

  final String icon;
  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppPalette.candyBlue.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: AppIcon(icon, size: 18, color: AppPalette.candyBlue),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                if (detail != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail!,
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReviewDivider extends StatelessWidget {
  const _ReviewDivider();

  @override
  Widget build(BuildContext context) {
    return Container(height: 1, color: AppPalette.hairline);
  }
}
