import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/analytics/analytics.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
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
/// and verifiable in the code. A control is added only when it is real.
///
/// The first one (plan 29E) is usage analytics: off stops the app recording
/// and sending anything at once, clears what was queued, and (signed in)
/// tells the server, which then drops anything still carrying the account
/// and deletes what it already holds.
class PrivacyControlsPage extends StatelessWidget {
  const PrivacyControlsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      // See verification_checklist_page.dart, which paints the app-bar strip too.
      extendBodyBehindAppBar: true,
      appBar: AppBar(title: const Text('Privacy controls')),
      body: AppBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
            children: [
              const SectionLabel('What we do today'),
              const SizedBox(height: 12),
              // ONE card, four rows.
              //
              // These were four separate cards, each icon + heading +
              // paragraph, stacked down the page. That shape says "four
              // unrelated objects"; they are four facts about one subject,
              // and reading them as a list is the point. It is also the
              // page-structure habit this redesign has been removing
              // everywhere else — the Safety checklist and the Profile
              // verification list are both one card with divided rows now,
              // so a page of loose cards no longer matches anything.
              FlatCard(
                radius: 18,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: const [
                    _Fact(
                      first: true,
                      icon: AppIcons.eye,
                      title: 'Who can see you',
                      body:
                          'Your name and photo are shared with other members of a '
                          'meetup once your request is accepted. Members below '
                          'Level 2 can see how many people are going, but not who '
                          'they are.',
                    ),
                    _Fact(
                      icon: AppIcons.pin,
                      title: 'Your location',
                      body:
                          'We use your approximate location to find meetups near '
                          'you, and we only read it while you have the browse '
                          'screen open. A meetup\'s exact address is shared with '
                          'the people going to it.',
                    ),
                    _Fact(
                      icon: AppIcons.shield,
                      title: 'Trusted contacts',
                      body:
                          'When you add someone, we text them once to ask whether '
                          'they agree. After that, nobody contacts them except you, '
                          'by sharing a meetup with them or by triggering SOS, and '
                          'only if they agreed. They are never shown to anyone else '
                          'on the app.',
                    ),
                    _Fact(
                      icon: AppIcons.search,
                      title: 'Searching for a place',
                      body:
                          'What you type into place search, and roughly where the '
                          'map is, goes to a map service to find matching places: '
                          'Apple Maps on iPhone, and Photon by komoot on Android, '
                          'with OpenStreetMap\'s Nominatim as a backup. When you '
                          'create a meetup, its pin goes to Nominatim to look up '
                          'the place name. None of them receive your name or '
                          'account.',
                    ),
                    _Fact(
                      icon: AppIcons.star,
                      title: 'Ratings you give',
                      body:
                          'The scores and traits you give after a meetup stay '
                          'private to you. Everyone sees their own overall rating, '
                          'but never who gave what.',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const SectionLabel('Your choices'),
              const SizedBox(height: 12),
              const FlatCard(
                radius: 18,
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: _AnalyticsToggle(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One fact, as a row inside the page's single card. Was `_FactCard`, one
/// card each; see the call site for why they were merged.
///
/// # THE PARAGRAPH STARTS FOLDED
///
/// All four bodies open at once made this page four paragraphs long, and
/// the screen set draws it as four labelled rows. Folding them keeps the
/// page scannable — a member opening Privacy controls is usually looking
/// for one of the four subjects — without taking the disclosure away:
/// every word is still one tap from where it was, on the row it belongs
/// to, rather than moved to a page nobody would find.
class _Fact extends StatefulWidget {
  const _Fact({
    required this.icon,
    required this.title,
    required this.body,
    this.first = false,
  });

  final String icon;
  final String title;
  final String body;

  /// The first row draws no rule above it.
  final bool first;

  @override
  State<_Fact> createState() => _FactState();
}

class _FactState extends State<_Fact> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (!widget.first) Divider(height: 1, color: AppPalette.hairline),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppPalette.tintedSurface(
                          AppPalette.textPrimary.withValues(alpha: 0.05),
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: AppIcon(
                        widget.icon,
                        size: 18,
                        color: AppPalette.candyBlue,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.title,
                        style: TextStyle(
                          color: AppPalette.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    AnimatedRotation(
                      turns: _open ? 0.25 : 0,
                      duration: const Duration(milliseconds: 160),
                      child: AppIcon(
                        AppIcons.forward,
                        size: 17,
                        color: AppPalette.textSecondary,
                      ),
                    ),
                  ],
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  child: _open
                      ? Padding(
                          padding: const EdgeInsets.only(top: 10, left: 46),
                          child: Text(
                            widget.body,
                            style: TextStyle(
                              color: AppPalette.textSecondary,
                              fontSize: 12.5,
                              height: 1.45,
                            ),
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Usage analytics on or off (plan 29 D8: on by default, with this
/// opt-out). The one line under it says what is collected; the full list is
/// in the privacy policy.
class _AnalyticsToggle extends StatefulWidget {
  const _AnalyticsToggle();

  @override
  State<_AnalyticsToggle> createState() => _AnalyticsToggleState();
}

class _AnalyticsToggleState extends State<_AnalyticsToggle> {
  late bool _on = !Analytics.instance.optedOut;

  Future<void> _set(bool on) async {
    setState(() => _on = on);
    await Analytics.instance.setOptedOut(!on);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
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
            child: AppIcon(
              AppIcons.bulb,
              size: 18,
              color: AppPalette.candyBlue,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Share usage analytics',
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Which screens and buttons you use, so we can fix what gets '
                  'in the way. Never your messages, contacts or location.',
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            key: const Key('analyticsToggle'),
            value: _on,
            onChanged: _set,
            activeTrackColor: AppPalette.candyBlue,
          ),
        ],
      ),
    );
  }
}
