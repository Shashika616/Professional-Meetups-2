import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/home/widgets/active_meetups_section.dart';
import 'package:professional_connections_platform/features/home/widgets/home_header.dart';
import 'package:professional_connections_platform/features/home/widgets/intent_grid.dart';
import 'package:professional_connections_platform/features/home/widgets/network_insights_row.dart';
import 'package:professional_connections_platform/features/home/widgets/safety_tip_card.dart';
import 'package:professional_connections_platform/features/meetups/schedule_flow.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedIntent = ref.watch(selectedIntentProvider);

    // Same pattern ProfilePage already uses (frontend/PLAN.md Step 13) —
    // fullName/profilePhotoUrl come from the cached session, "Member" is
    // the fallback while it's still loading or genuinely absent, and an
    // empty (not just null) photo URL is treated as "no photo" so
    // ProfessionalAvatar doesn't try to load an empty Image.network src.
    final profile = ref.watch(authSessionProvider).value?.profile;
    final fullName = profile?.fullName;
    final displayName = (fullName == null || fullName.isEmpty)
        ? 'Member'
        : fullName;
    final imageUrl = (profile?.profilePhotoUrl.isNotEmpty ?? false)
        ? profile!.profilePhotoUrl
        : null;
    // Level 0 (no profile resolved yet) is the safe default while loading —
    // ADR-014 made Level 0 (Apple/Google/email, no LinkedIn) a real,
    // reachable account state, not just "still loading," so this must never
    // assume a higher level than what's actually confirmed.
    final trustLevel = profile?.trustLevel ?? 0;

    // ADR-032 Step 4 — the FIND MATCHES / HOST YOUR OWN MEETUP CTAs used to
    // scroll with everything else; they now live in a fixed, non-scrolling
    // block anchored above AppShell's persistent nav bar (mirrors how
    // Uber/most consumer apps anchor the primary action), while everything
    // else on this page keeps scrolling in the Expanded ListView above it.
    // Both buttons' onPressed bodies (trust-gate check, toast, navigation,
    // provider invalidation) are unchanged — this is a position change only.
    void onFindMatches() {
      if (!selectedIntent.isUnlockedFor(trustLevel)) {
        showSnack(
          context,
          '${selectedIntent.label} requires Level ${selectedIntent.requiredTrustLevel} trust, Verify your phone, personal email, and details in Profile to unlock it.',
          type: ToastType.locked,
        );
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const VerificationChecklistPage()),
        );
        return;
      }
      // Browse open meetups for the selected intent — the Matches tab
      // (index 1) is the real surface for this now (ADR-013 § 7), not a
      // toast.
      ref.read(currentTabIndexProvider.notifier).state = 1;
    }

    Future<void> onHostMeetup() async {
      if (!selectedIntent.isUnlockedFor(trustLevel)) {
        showSnack(
          context,
          '${selectedIntent.label} requires Level ${selectedIntent.requiredTrustLevel} trust, Verify your phone, personal email, and details in Profile to unlock it.',
          type: ToastType.locked,
        );
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const VerificationChecklistPage()),
        );
        return;
      }
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const ScheduleFlowPage()));
      // Invalidates every cached (intent, viewerLat, viewerLng) instance of
      // this family, not just one — this screen doesn't know the browse
      // screen's last-used coordinate (ADR-021 §2 made that part of the
      // provider's own key), and a freshly-hosted meetup should invalidate
      // whatever the browse screen shows next regardless.
      ref.invalidate(openMeetupsProvider);
      ref.invalidate(myMeetupsProvider);
      ref.invalidate(activeMeetupsProvider);
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              // ADR-030 (round-9) — the other real (not cosmetic) refetch
              // path for the active-meetups list, alongside AppShell's
              // app-resume hook. Same RefreshIndicator pattern
              // matches_page.dart's browse list already uses. Scoped to
              // activeMeetupsProvider specifically — this page has nothing
              // else worth a network refetch on pull.
              child: RefreshIndicator(
                onRefresh: () => ref.refresh(activeMeetupsProvider.future),
                child: ListView(
                  padding: EdgeInsets.zero,
                  addAutomaticKeepAlives: true,
                  addRepaintBoundaries: true,
                  children: [
                    HomeHeader(userName: displayName, imageUrl: imageUrl),
                    const SizedBox(height: 8),
                    IntentGrid(trustLevel: trustLevel),
                    const ActiveMeetupsSection(),
                    const NetworkInsightsRow(),
                    const SafetyTipCard(),
                    // Clearance above the fixed CTA block below, not the old
                    // 96 — that was clearance for the buttons' previous
                    // floating position in the scrolling list, which no
                    // longer applies now that they render in their own
                    // fixed block underneath this list.
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Column(
                children: [
                  PrimaryButton(
                    label: 'FIND MATCHES',
                    onPressed: onFindMatches,
                  ),
                  const SizedBox(height: 8),
                  // A separate entry point from FIND MATCHES, not a "+" icon
                  // buried in the browse page's AppBar (where it used to
                  // live) — someone opening the browse list wants to see
                  // other people's open meetups, not stumble into hosting
                  // one.
                  //
                  // round-7 hardening: this button used to have no trust
                  // gate of its own at all — it unconditionally pushed
                  // ScheduleFlowPage, deferring entirely to that flow's own
                  // nested intent step (toast-only, no redirect). Added a
                  // real gate here, same isUnlockedFor check FIND MATCHES
                  // above already does, so a trust-level-0 user can no
                  // longer tap straight into the scheduling UI before ever
                  // hitting a lock check. ScheduleFlowPage's own intent step
                  // gate stays too — a backstop for a user changing intent
                  // mid-flow, not removed by adding this outer gate.
                  OutlinedButton.icon(
                    onPressed: onHostMeetup,
                    icon: Icon(
                      Icons.add_circle_outline,
                      size: 16,
                      color: AppPalette.verified,
                    ),
                    label: Text(
                      'HOST YOUR OWN MEETUP',
                      style: TextStyle(
                        color: AppPalette.verified,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      backgroundColor: AppPalette.verified.withValues(
                        alpha: 0.08,
                      ),
                      side: BorderSide(
                        color: AppPalette.verified.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
