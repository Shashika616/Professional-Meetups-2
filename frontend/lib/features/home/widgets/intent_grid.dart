import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/section_label.dart';
import 'package:professional_connections_platform/features/home/widgets/intent_picker_sheet.dart';
import 'package:professional_connections_platform/features/home/widgets/intent_tile.dart';

class IntentGrid extends ConsumerWidget {
  const IntentGrid({super.key, required this.trustLevel});

  final int trustLevel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedIntentProvider);
    final unlocked = IntentType.values
        .where((intent) => intent.isUnlockedFor(trustLevel))
        .toList();
    final visible = <IntentType>[
      selected,
      ...unlocked.where((intent) => intent != selected),
    ].take(3).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: SectionLabel('WHAT WOULD YOU LIKE TO DO TODAY?'),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 2.1,
            children: [
              for (final intent in visible)
                IntentTile(
                  intent: intent,
                  selected: intent == selected,
                  locked: false,
                  onTap: () =>
                      ref.read(selectedIntentProvider.notifier).state = intent,
                ),
              _MoreTile(onTap: () => IntentPickerSheet.show(context)),
            ],
          ),
        ),
      ],
    );
  }
}

class _MoreTile extends StatelessWidget {
  const _MoreTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: FlatCard(
        radius: 10,
        padding: const EdgeInsets.all(14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.apps_rounded, size: 20, color: AppPalette.candyBlue),
            SizedBox(width: 8),
            Text(
              'MORE',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
                color: AppPalette.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
