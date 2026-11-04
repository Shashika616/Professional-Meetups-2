part of 'schedule_flow.dart';

/// Title row plus a step counter and a thin progress track — a five-step
/// wizard with no indication of where you are in it is the single most
/// common thing missing from flows like this, and the fix is cheap.
class _Header extends StatelessWidget {
  const _Header({
    required this.onBack,
    required this.step,
    required this.total,
  });

  final VoidCallback onBack;
  final int step;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // Was a hardcoded iOS chevron, which Android users saw too.
              AppBackButton(onPressed: onBack),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Schedule a meetup',
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              Text(
                'STEP $step OF $total',
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: step / total),
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => LinearProgressIndicator(
                  value: value,
                  minHeight: 3,
                  backgroundColor: AppPalette.hairline,
                  color: AppPalette.brandGreen,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepTitle extends StatelessWidget {
  const _StepTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w800,
          color: AppPalette.textPrimary,
          height: 1.2,
        ),
      ),
    );
  }
}

class _IntentStep extends StatelessWidget {
  const _IntentStep({
    required this.trustLevel,
    required this.selected,
    required this.onPick,
  });

  final int trustLevel;
  final IntentType? selected;
  final void Function(IntentType intent) onPick;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StepTitle('What kind of meetup?'),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          // Image cards, not icon rows: roughly square so the scene reads
          // and there is room under it for the icon chip and name.
          childAspectRatio: 1.04,
          children: [
            for (final intent in IntentType.values)
              IntentTile(
                intent: intent,
                selected: intent == selected,
                locked: !intent.canHost(trustLevel),
                onTap: () {
                  // HOST-side gate (ADR-002 § 4) — this is the scheduling
                  // flow, so every intent here is being chosen to host.
                  //
                  // The destination is HostingUnlockPage, not the Level 2
                  // checklist. ADR-002 § 4 split the two gates but this call
                  // site kept the old redirect, so a Level 2 user — who can
                  // already join meetups — was sent to a page listing four
                  // things they finished long ago, with nothing on it that
                  // would actually unlock hosting. home_page.dart's
                  // onHostMeetup already routed correctly; this now matches.
                  // Deferred intents (ADR-004) are not a level to earn —
                  // sending someone to the unlock page for them promises
                  // something the page cannot deliver. Say so and stop.
                  if (intent.hostingDeferred) {
                    showSnack(
                      context,
                      '${intent.label[0]}${intent.label.substring(1).toLowerCase()} '
                      'meetups are not available yet.',
                      type: ToastType.locked,
                    );
                    return;
                  }
                  if (!intent.canHost(trustLevel)) {
                    showSnack(
                      context,
                      intent.hostLockedMessage,
                      type: ToastType.locked,
                    );
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        settings: const RouteSettings(
                          name: ScreenNames.hostingUnlock,
                        ),
                        builder: (_) => const HostingUnlockPage(),
                      ),
                    );
                    return;
                  }
                  onPick(intent);
                },
              ),
          ],
        ),
      ],
    );
  }
}
