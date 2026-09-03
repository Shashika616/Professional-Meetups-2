import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/section_label.dart';
import 'package:professional_connections_platform/features/profile/profile_page.dart'
    show ConnectLinkedInBanner;
import 'package:professional_connections_platform/features/verification/personal_details_page.dart';
import 'package:professional_connections_platform/features/verification/personal_email_verification_page.dart';
import 'package:professional_connections_platform/features/verification/phone_verification_page.dart';

/// A focused checklist scoped to exactly Level 2's four requirements —
/// LinkedIn, phone, personal email, personal details (ADR-028 § 3;
/// **not** corporate/work email, that's Level 3 and out of scope here).
///
/// Reached from tapping a trust-locked meetup card or its join button
/// (`matches_page.dart`'s `_MeetupCard`, `meetup_detail_page.dart`'s join
/// action). Distinct from two things that already exist and aren't reused
/// here: `onboarding_flow.dart`'s `runVerificationSequence` (auto-advances
/// through every incomplete step in one sequential wizard, no per-item
/// visibility) and the full `ProfilePage` (every account setting, not a
/// focused "here's what's blocking you" view). Every row pushes the exact
/// same verification-page widget `ProfilePage`'s own VERIFICATION section
/// uses — no new OTP/verification logic lives here.
///
/// A [ConsumerWidget], not stateful — the pushed verification pages already
/// update `authSessionProvider` on their own success (same mechanism
/// `ProfilePage` relies on, per its own doc comment), so popping back here
/// re-renders reactively via `ref.watch` with no manual refetch needed.
class VerificationChecklistPage extends ConsumerWidget {
  const VerificationChecklistPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(authSessionProvider).value?.profile;
    final linkedInConnected = profile?.linkedInConnected ?? false;
    final phoneDone = profile?.phoneVerified ?? false;
    final emailDone = profile?.personalEmailVerified ?? false;
    final detailsDone = profile?.personalDetailsComplete ?? false;
    final allDone = linkedInConnected && phoneDone && emailDone && detailsDone;

    return Scaffold(
      backgroundColor: Colors.transparent,
      // Without this, the AppBar's own (transparent) region isn't covered
      // by AppBackground at all — body painting starts below the app bar,
      // so that strip shows through to nothing but plain black instead of
      // the same image/gradient as the rest of the screen. This also
      // widens MediaQuery's top padding to include the app bar's height,
      // so the SafeArea below still pushes content clear of the title row.
      // Same fix as profile_setup_screen.dart's identical Scaffold shape.
      extendBodyBehindAppBar: true,
      appBar: AppBar(title: const Text('UNLOCK JOINING MEETUPS')),
      body: AppBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
            children: [
              Text(
                'Complete these to reach Level 2 trust and unlock joining meetups.',
                style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 20),
              if (!linkedInConnected) ...[
                const ConnectLinkedInBanner(),
                const SizedBox(height: 20),
              ],
              const SectionLabel('REMAINING STEPS'),
              const SizedBox(height: 12),
              FlatCard(
                radius: 12,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Column(
                  children: [
                    _ChecklistRow(
                      icon: Icons.phone_android,
                      title: 'Phone',
                      done: phoneDone,
                      locked: !linkedInConnected,
                      buildScreen: (context) => PhoneVerificationPage(
                        currentValue: profile?.phoneNumber,
                      ),
                    ),
                    const _ChecklistDivider(),
                    _ChecklistRow(
                      icon: Icons.alternate_email_rounded,
                      title: 'Personal Email',
                      done: emailDone,
                      locked: !linkedInConnected,
                      buildScreen: (context) => PersonalEmailVerificationPage(
                        currentValue: profile?.personalEmail,
                      ),
                    ),
                    const _ChecklistDivider(),
                    _ChecklistRow(
                      icon: Icons.badge_outlined,
                      title: 'Personal Details',
                      done: detailsDone,
                      locked: !linkedInConnected,
                      buildScreen: (context) =>
                          PersonalDetailsPage(profile: profile),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              // Does not retry the join action that led here (ADR-028 § 3)
              // — pops back and lets the next tap on REQUEST TO JOIN simply
              // work now that the meetup is no longer locked for this
              // viewer.
              PrimaryButton(
                label: 'COMPLETE',
                height: 48,
                onPressed: allDone ? () => Navigator.of(context).pop() : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChecklistRow extends StatelessWidget {
  const _ChecklistRow({
    required this.icon,
    required this.title,
    required this.done,
    required this.locked,
    required this.buildScreen,
  });

  final IconData icon;
  final String title;
  final bool done;
  final bool locked;
  final WidgetBuilder buildScreen;

  @override
  Widget build(BuildContext context) {
    final trailing = done
        ? Icon(Icons.check_circle_rounded, size: 18, color: AppPalette.verified)
        : locked
        ? Icon(
            Icons.lock_outline_rounded,
            size: 16,
            color: AppPalette.textSecondary,
          )
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: AppPalette.candyBlue.withValues(alpha: 0.5),
              ),
            ),
            child: Text(
              'VERIFY',
              style: TextStyle(
                fontSize: 8,
                letterSpacing: 1.4,
                fontWeight: FontWeight.w800,
                color: AppPalette.candyBlue,
              ),
            ),
          );

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: AppPalette.candyBlue),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  done
                      ? 'Verified'
                      : locked
                      ? 'Connect LinkedIn first'
                      : 'Not verified',
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );

    if (locked) return row;
    return GestureDetector(
      onTap: () =>
          Navigator.push(context, MaterialPageRoute(builder: buildScreen)),
      child: row,
    );
  }
}

class _ChecklistDivider extends StatelessWidget {
  const _ChecklistDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      color: AppPalette.glassBorder,
      margin: const EdgeInsets.symmetric(vertical: 2),
    );
  }
}
