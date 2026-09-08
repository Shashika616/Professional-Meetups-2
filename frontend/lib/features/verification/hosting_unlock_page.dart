import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/section_label.dart';
import 'package:professional_connections_platform/features/verification/corporate_email_verification_page.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

/// The Level 2 → 3 flow: what a user has to do before they can HOST a meetup
/// (ADR-002 § 4/§ 6, canonical decision ADR-033 § 4).
///
/// Sibling to [VerificationChecklistPage] ("UNLOCK JOINING MEETUPS") and
/// deliberately the same visual pattern, because they answer the same shape
/// of question at two different rungs. That page is unchanged by ADR-002 and
/// is NOT reused here: its scope is Level 2's four items, and a user who
/// reaches this page has already completed all of them.
///
/// # WHY BOTH NEW ROWS LEAD TO THE SAME PAGE
///
/// Level 3 needs a company NAME and a VERIFIED company EMAIL. They are shown
/// as two rows because they are two requirements a user has to satisfy, and a
/// checklist that hid one of them would under-explain what is being asked.
///
/// But both rows open [CorporateEmailVerificationPage], because that page
/// already collects both — it has always required the company name alongside
/// the address, for the known-companies name-vs-domain cross-check
/// (ADR-019 § 3) — and because the backend writes both in a single statement
/// (ADR-002 § 2). There is no way to save the name alone, and deliberately
/// so: a name with no verified email advances nothing, and storing them
/// apart would let the row hold one without the other, which is exactly what
/// the Level 3 condition forbids.
///
/// That is also why no new RPC was added for the name. See the completion
/// report's § B for the full reasoning.
///
/// A [ConsumerWidget], not stateful, for the same reason as
/// [VerificationChecklistPage]: the pushed verification page updates
/// `authSessionProvider` itself on success, so popping back here re-renders
/// through `ref.watch` with no manual refetch.
class HostingUnlockPage extends ConsumerWidget {
  const HostingUnlockPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(authSessionProvider).value?.profile;

    // Level 2's four items. Rendered as context, not as work — this page is
    // normally reached with all four already done.
    final linkedInConnected = profile?.linkedInConnected ?? false;
    final phoneDone = profile?.phoneVerified ?? false;
    final emailDone = profile?.personalEmailVerified ?? false;
    final detailsDone = profile?.personalDetailsComplete ?? false;
    final levelTwoDone =
        linkedInConnected && phoneDone && emailDone && detailsDone;

    // The two new Level 3 items.
    final companyNameDone = (profile?.companyName ?? '').isNotEmpty;
    final companyEmailDone = profile?.workEmailVerified ?? false;

    // COMPLETE gates on the two new rows, per ADR-002 § 6 — but Level 2 is a
    // genuine prerequisite, so it is required here too. Without that, a user
    // who somehow reached this page mid-Level-2 could complete both new rows
    // and still not be Level 3, and the button would have lied to them.
    final canHost = levelTwoDone && companyNameDone && companyEmailDone;

    return Scaffold(
      backgroundColor: Colors.transparent,
      // Same Scaffold shape as VerificationChecklistPage — see its comment
      // for why extendBodyBehindAppBar is load-bearing with AppBackground.
      extendBodyBehindAppBar: true,
      appBar: AppBar(title: const Text('UNLOCK HOSTING MEETUPS')),
      body: AppBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
            children: [
              Text(
                'Hosting a meetup means taking responsibility for a real gathering, '
                'so it asks for a little more than joining one. Add your organisation '
                'to reach Level 3 trust.',
                style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 20),

              // Shown only when the prerequisite is genuinely unmet, so the
              // normal case is not cluttered with a block about steps the
              // user finished long ago.
              if (!levelTwoDone) ...[
                _LevelTwoPrerequisite(
                  linkedInConnected: linkedInConnected,
                  phoneDone: phoneDone,
                  emailDone: emailDone,
                  detailsDone: detailsDone,
                ),
                const SizedBox(height: 20),
              ],

              const SectionLabel('YOUR ORGANISATION'),
              const SizedBox(height: 12),
              FlatCard(
                radius: 12,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Column(
                  children: [
                    _HostingRow(
                      key: const Key('hostingUnlockCompanyNameRow'),
                      icon: Icons.business_outlined,
                      title: 'Company / Organisation',
                      doneLabel: profile?.companyName ?? '',
                      pendingLabel: 'Not added',
                      done: companyNameDone,
                      locked: !levelTwoDone,
                      onTap: () => _openCompanyVerification(context, profile),
                    ),
                    const _HostingDivider(),
                    _HostingRow(
                      key: const Key('hostingUnlockCompanyEmailRow'),
                      icon: Icons.mail_outline_rounded,
                      title: 'Company / Organisation Email',
                      doneLabel: 'Verified',
                      pendingLabel: 'Not verified',
                      done: companyEmailDone,
                      locked: !levelTwoDone,
                      onTap: () => _openCompanyVerification(context, profile),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Both are set together, entering your organisation name is part of '
                'verifying its email address.',
                style: TextStyle(color: AppPalette.textSecondary, fontSize: 11),
              ),
              const SizedBox(height: 28),
              // Pops rather than retrying the host action that led here, the
              // same choice VerificationChecklistPage makes (ADR-028 § 3):
              // the next tap on HOST simply works now.
              PrimaryButton(
                key: const Key('hostingUnlockComplete'),
                label: 'COMPLETE',
                height: 48,
                onPressed: canHost ? () => Navigator.of(context).pop() : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static void _openCompanyVerification(BuildContext context, profile) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CorporateEmailVerificationPage(
          currentDomainHint: profile?.companyDomain as String?,
        ),
      ),
    );
  }
}

/// The Level 2 prerequisite block, shown only when it is not yet met.
/// Deliberately a signpost rather than a second copy of the Level 2
/// checklist: [VerificationChecklistPage] already is that page, and
/// duplicating its rows here would be two things to keep in step.
class _LevelTwoPrerequisite extends StatelessWidget {
  const _LevelTwoPrerequisite({
    required this.linkedInConnected,
    required this.phoneDone,
    required this.emailDone,
    required this.detailsDone,
  });

  final bool linkedInConnected;
  final bool phoneDone;
  final bool emailDone;
  final bool detailsDone;

  @override
  Widget build(BuildContext context) {
    final remaining = <String>[
      if (!linkedInConnected) 'LinkedIn',
      if (!phoneDone) 'phone',
      if (!emailDone) 'personal email',
      if (!detailsDone) 'personal details',
    ];

    return FlatCard(
      radius: 12,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 18,
                color: AppPalette.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  key: const Key('hostingUnlockLevelTwoHeading'),
                  'Finish Level 2 first',
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Still needed: ${remaining.join(', ')}.',
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            key: const Key('hostingUnlockLevelTwoLink'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const VerificationChecklistPage(),
              ),
            ),
            child: Text(
              'Unlock joining meetups →',
              style: TextStyle(
                color: AppPalette.candyBlue,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One row. Same visual grammar as [VerificationChecklistPage]'s own rows;
/// kept as its own widget rather than exported from there because the
/// subtitle here is data (the organisation's name) rather than a fixed
/// status string.
class _HostingRow extends StatelessWidget {
  const _HostingRow({
    super.key,
    required this.icon,
    required this.title,
    required this.doneLabel,
    required this.pendingLabel,
    required this.done,
    required this.locked,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String doneLabel;
  final String pendingLabel;
  final bool done;
  final bool locked;
  final VoidCallback onTap;

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
              'ADD',
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
              color: AppPalette.tintedSurface(
                AppPalette.textPrimary.withValues(alpha: 0.05),
              ),
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
                      ? doneLabel
                      : locked
                      ? 'Finish Level 2 first'
                      : pendingLabel,
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
    return GestureDetector(onTap: onTap, child: row);
  }
}

class _HostingDivider extends StatelessWidget {
  const _HostingDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      color: AppPalette.hairline,
      margin: const EdgeInsets.symmetric(vertical: 2),
    );
  }
}
