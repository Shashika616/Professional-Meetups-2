import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/section_label.dart';

class IntentSlider extends ConsumerWidget {
  const IntentSlider({super.key, required this.trustLevel});

  final int trustLevel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedIntent = ref.watch(selectedIntentProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: SectionLabel('SELECT YOUR INTENT'),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 130,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: IntentType.values.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final intent = IntentType.values[index];
              return _IntentCard(
                intent: intent,
                selected: selectedIntent == intent,
                trustLevel: trustLevel,
                onTap: () {
                  if (!intent.isUnlockedFor(trustLevel)) {
                    showSnack(
                      context,
                      '${intent.label} requires Level ${intent.requiredTrustLevel} trust.',
                    );
                    return;
                  }
                  ref.read(selectedIntentProvider.notifier).state = intent;
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _IntentCard extends StatelessWidget {
  const _IntentCard({
    required this.intent,
    required this.selected,
    required this.trustLevel,
    required this.onTap,
  });

  final IntentType intent;
  final bool selected;
  final int trustLevel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool locked = !intent.isUnlockedFor(trustLevel);
    final bool isSelected = selected && !locked;

    return GestureDetector(
      onTap: onTap,
      child: FlatCard(
        radius: 12,
        padding: const EdgeInsets.all(16),
        tint: isSelected ? AppPalette.candyBlue.withValues(alpha: 0.15) : null,
        border: isSelected ? AppPalette.candyBlue.withValues(alpha: 0.6) : null,
        child: SizedBox(
          width: 110,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppPalette.candyBlue.withValues(alpha: 0.2)
                      : Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  intent.icon,
                  size: 22,
                  color: locked
                      ? AppPalette.textSecondary
                      : AppPalette.candyBlue,
                ),
              ),
              const Spacer(),
              Text(
                intent.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: locked
                      ? AppPalette.textSecondary
                      : AppPalette.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                locked ? 'LOCKED' : 'ACTIVE',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                  color: locked
                      ? AppPalette.danger.withValues(alpha: 0.8)
                      : AppPalette.verified,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
