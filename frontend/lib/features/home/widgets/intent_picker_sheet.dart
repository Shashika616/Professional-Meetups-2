import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/widgets/section_label.dart';
import 'package:professional_connections_platform/features/home/widgets/intent_tile.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

/// Round-9 hardening (docs/00-project/action-tracker.md § 4b-22) — used to
/// take `trustLevel` as a constructor field, captured once when the sheet
/// was shown. Every other trust-gate redirect site (`matches_page.dart`,
/// `meetup_detail_page.dart`, `schedule_flow.dart`, ...) reads it live via
/// `ref.watch(authSessionProvider)` instead; this sheet now does too, so a
/// user who completes verification while it happens to still be open sees
/// tiles unlock immediately rather than needing to close and reopen it.
class IntentPickerSheet extends ConsumerWidget {
  const IntentPickerSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: AppPalette.onyx.withValues(alpha: 0.65),
      isScrollControlled: true,
      transitionAnimationController: AnimationController(
        vsync: Navigator.of(context),
        duration: const Duration(milliseconds: 300),
      ),
      builder: (context) => const IntentPickerSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedIntentProvider);
    final trustLevel =
        ref.watch(authSessionProvider).value?.profile?.trustLevel ?? 0;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      // ADR-032 Step 5 — this sheet used its own local backdrop blur filter
      // (separate from the shared FlatCard widget, so it wasn't touched by
      // that rename) over a translucent AppPalette.surface. Now a solid,
      // fully-opaque background — no blur — same as every other flattened
      // surface in this redesign. barrierColor (the modal scrim behind the
      // sheet, set in show() above) is unrelated to this and stays as-is.
      child: Container(
        color: AppPalette.surface,
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          MediaQuery.of(context).padding.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const SectionLabel('ALL INTENTS'),
            const SizedBox(height: 16),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 2.1,
              children: [
                for (final intent in IntentType.values)
                  IntentTile(
                    intent: intent,
                    selected: intent == selected,
                    locked: !intent.isUnlockedFor(trustLevel),
                    onTap: () {
                      if (!intent.isUnlockedFor(trustLevel)) {
                        // Non-punitive: names the specific unlock path
                        // (Profile's verification rows, ADR-013 § 2)
                        // rather than a bare "locked" dead end.
                        showSnack(
                          context,
                          '${intent.label} requires Level ${intent.requiredTrustLevel} trust. Verify your phone, personal email, and details in Profile to unlock it.',
                          type: ToastType.locked,
                        );
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const VerificationChecklistPage(),
                          ),
                        );
                        return;
                      }
                      ref.read(selectedIntentProvider.notifier).state = intent;
                      Navigator.of(context).pop();
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
