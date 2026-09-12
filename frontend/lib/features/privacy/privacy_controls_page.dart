import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/section_label.dart';

/// Privacy Controls.
///
/// # WHY THIS IS A PLACEHOLDER AND NOT A SET OF SWITCHES
///
/// The row in Profile has pointed here since it was written, but nothing was
/// behind it: a chevron that did nothing when tapped. This gives it a real
/// destination.
///
/// It deliberately ships with no controls yet. A privacy toggle is a promise
/// about what the server does with someone's data, and a switch that renders
/// but changes nothing is worse than no switch at all. That is the exact
/// failure the live-location opt-in already had once (see
/// `meetup/safety.go`'s ShareWithContacts: "a safety feature that only
/// appeared to work, which is worse than not offering one").
///
/// So this page states what the app currently does, which is all true today
/// and verifiable in the code, and says plainly that the controls are
/// coming. When a real toggle exists it replaces the matching line here.
class PrivacyControlsPage extends StatelessWidget {
  const PrivacyControlsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      // See verification_checklist_page.dart, which paints the app-bar strip too.
      extendBodyBehindAppBar: true,
      appBar: AppBar(title: const Text('PRIVACY CONTROLS')),
      body: AppBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
            children: [
              const SectionLabel('WHAT WE DO TODAY'),
              const SizedBox(height: 12),
              const _FactCard(
                icon: Icons.visibility_outlined,
                title: 'Who can see you',
                body:
                    'Your name and photo are shared with other members of a '
                    'meetup once your request is accepted. Members below '
                    'Level 2 can see how many people are going, but not who '
                    'they are.',
              ),
              const SizedBox(height: 10),
              const _FactCard(
                icon: Icons.place_outlined,
                title: 'Your location',
                body:
                    'We use your approximate location to find meetups near '
                    'you, and we only read it while you have the browse '
                    'screen open. A meetup\'s exact address is shared with '
                    'the people going to it.',
              ),
              const SizedBox(height: 10),
              const _FactCard(
                icon: Icons.shield_outlined,
                title: 'Trusted contacts',
                body:
                    'Nobody contacts your trusted contacts except you, either '
                    'by sharing a meetup with them or by triggering SOS. They '
                    'are never shown to anyone else on the app.',
              ),
              const SizedBox(height: 10),
              const _FactCard(
                icon: Icons.star_outline_rounded,
                title: 'Ratings you give',
                body:
                    'The scores and traits you give after a meetup stay '
                    'private to you. Everyone sees their own overall rating, '
                    'but never who gave what.',
              ),
              const SizedBox(height: 24),
              FlatCard(
                radius: 12,
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.tune_rounded,
                      size: 18,
                      color: AppPalette.textSecondary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Controls are coming',
                            style: TextStyle(
                              color: AppPalette.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Settings to change any of the above will appear '
                            'here. Nothing on this page is adjustable yet. '
                            'We would rather show you no switch at all than '
                            'one that quietly does nothing.',
                            style: TextStyle(
                              color: AppPalette.textSecondary,
                              fontSize: 12.5,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FactCard extends StatelessWidget {
  const _FactCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return FlatCard(
      radius: 12,
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
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
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
