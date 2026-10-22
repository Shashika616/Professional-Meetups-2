// DEV-ONLY ENTRY POINT. Not reachable from the shipped app: `main.dart` is
// the default target, and nothing imports this file. Run it with
//
//     flutter run -t lib/main_preview.dart --dart-define=PREVIEW_THEME=light
//
// to put every shared surface on one screen at once. It exists because a
// token/redesign change is invisible to the test suite — every assertion
// can pass while the result looks wrong — and the only honest review of a
// visual change is to look at it on a real device.
import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_banner.dart';
import 'package:professional_connections_platform/core/widgets/app_bottom_bar.dart';
import 'package:professional_connections_platform/core/widgets/app_chip.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/app_tag.dart';
import 'package:professional_connections_platform/core/widgets/app_text_field.dart';
import 'package:professional_connections_platform/core/widgets/brand_marks.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/otp_box_field.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/core/widgets/section_heading.dart';
import 'package:professional_connections_platform/core/widgets/square_icon_tile.dart';
import 'package:professional_connections_platform/core/widgets/stat_tile.dart';
import 'package:professional_connections_platform/core/widgets/step_progress.dart';
import 'package:professional_connections_platform/core/widgets/trust_level_badge.dart';

const _theme = String.fromEnvironment('PREVIEW_THEME', defaultValue: 'dark');

void main() {
  AppPalette.setMode(
    _theme == 'light' ? AppThemeMode.light : AppThemeMode.dark,
  );
  runApp(const _PreviewApp());
}

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    final light = AppPalette.isLight;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: light ? Brightness.light : Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: AppPalette.onyx,
      ),
      home: const _PreviewPage(),
    );
  }
}

class _PreviewPage extends StatefulWidget {
  const _PreviewPage();
  @override
  State<_PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<_PreviewPage> {
  final _filled = TextEditingController(text: 'Alex Perera');
  final _empty = TextEditingController();
  final _otp = TextEditingController(text: '481');
  int _page = 0;
  int _chip = 0;

  @override
  void dispose() {
    _filled.dispose();
    _empty.dispose();
    _otp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _header(),
              const SizedBox(height: 18),
              const SectionHeading('HAPPENING SOON'),
              const SizedBox(height: 10),
              _chips(),
              const SizedBox(height: 12),
              _meetupCard(),
              const SizedBox(height: 14),
              const SectionHeading('BANNERS'),
              const SizedBox(height: 10),
              AppBanner(
                icon: AppIcons.work,
                title: 'Connect LinkedIn',
                message: 'Your account is view only until you do.',
                trailing: AppIcon(
                  AppIcons.forward,
                  size: 18,
                  color: AppPalette.candyBlue,
                ),
              ),
              const SizedBox(height: 8),
              const AppBanner(
                icon: AppIcons.check,
                tone: AppTone.success,
                title: "You're in",
                message: 'The host accepted your request. See you there.',
              ),
              const SizedBox(height: 8),
              const AppBanner(
                icon: AppIcons.clock,
                tone: AppTone.warning,
                title: 'Request pending',
                message: 'Waiting for the host to respond.',
              ),
              const SizedBox(height: 8),
              const AppBanner(
                icon: AppIcons.close,
                tone: AppTone.danger,
                title: 'Cancelled by the host',
              ),
              const SizedBox(height: 16),
              const SectionHeading('STATS'),
              const SizedBox(height: 10),
              const StatTileRow(
                tiles: [
                  StatTile(value: '12', label: 'Meetups'),
                  StatTile(value: '4.8', label: 'Rating'),
                  StatTile(value: '3', label: 'Trust level'),
                ],
              ),
              const SizedBox(height: 16),
              const SectionHeading('VERIFICATION ROWS'),
              const SizedBox(height: 10),
              _verificationRows(),
              const SizedBox(height: 16),
              const SectionHeading('STEP PROGRESS'),
              const SizedBox(height: 12),
              const StepProgress(total: 5, current: 3),
              const SizedBox(height: 18),
              const SectionHeading('FIELDS'),
              const SizedBox(height: 10),
              AppTextField(
                controller: _filled,
                icon: AppIcons.person,
                hint: 'Full name',
              ),
              const SizedBox(height: 10),
              AppTextField(
                controller: _empty,
                icon: AppIcons.mail,
                hint: 'Work email',
              ),
              const SizedBox(height: 14),
              OtpBoxField(controller: _otp, autofocus: false),
              const SizedBox(height: 20),
              const SectionHeading('BUTTONS'),
              const SizedBox(height: 10),
              PrimaryButton(label: 'Host your own meetup', onPressed: () {}),
              const SizedBox(height: 10),
              SecondaryButton(label: 'Cancel request', onPressed: () {}),
              const SizedBox(height: 10),
              SecondaryButton(
                label: 'Cancel meetup',
                color: AppPalette.danger,
                borderColor: AppPalette.danger,
                fillColor: Colors.transparent,
                onPressed: () {},
              ),
              const SizedBox(height: 10),
              PrimaryButton(label: 'Disabled action', onPressed: null),
              const SizedBox(height: 20),
              const SectionHeading('PROVIDER SIGN-IN'),
              const SizedBox(height: 10),
              _provider('Continue with Apple', const AppleMark()),
              const SizedBox(height: 10),
              _provider('Continue with Google', const GoogleMark()),
              const SizedBox(height: 10),
              _provider('Continue with LinkedIn', const LinkedInMark()),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
      bottomNavigationBar: AppBottomBar(
        index: _page,
        onTap: (i) => setState(() => _page = i),
      ),
    );
  }

  Widget _provider(String label, Widget mark) => PrimaryButton(
    label: label,
    iconWidget: mark,
    fillColor: AppPalette.card,
    foregroundColor: AppPalette.textPrimary,
    borderColor: AppPalette.hairline,
    onPressed: () {},
  );

  Widget _header() => Row(
    children: [
      const ProfessionalAvatar(
        size: 40,
        name: 'Alex Perera',
        ring: true,
        showPresenceDot: true,
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Good afternoon',
              style: TextStyle(color: AppPalette.textSecondary, fontSize: 12.5),
            ),
            Text(
              'Alex Perera',
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 19,
                height: 1.15,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
              ),
            ),
          ],
        ),
      ),
      AppIcon(AppIcons.bell, size: 23, color: AppPalette.textSecondary),
    ],
  );

  Widget _chips() => SizedBox(
    height: 40,
    child: ListView(
      scrollDirection: Axis.horizontal,
      children: [
        for (final (i, c) in const [
          ('All', AppIcons.grid, false),
          ('Coffee', AppIcons.coffee, false),
          ('Meal', AppIcons.meal, false),
          ('Networking', AppIcons.people, false),
          ('Mentorship', AppIcons.mentorship, true),
        ].indexed) ...[
          if (i > 0) const SizedBox(width: 7),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: AppChip(
              label: c.$1,
              icon: c.$2,
              locked: c.$3,
              selected: _chip == i,
              onTap: () => setState(() => _chip = i),
            ),
          ),
        ],
      ],
    ),
  );

  Widget _meetupCard() => FlatCard(
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const AppTag('Coffee'),
            const SizedBox(width: 6),
            const AppTag("You're in", tone: AppTone.success),
            const Spacer(),
            Text(
              '2/4',
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Thu, 5:30 – 6:30 PM',
          style: TextStyle(
            color: AppPalette.textPrimary,
            fontSize: 15.5,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'Cafe Kumbuk, Colombo 07',
          style: TextStyle(color: AppPalette.textSecondary, fontSize: 12.5),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const ProfessionalAvatar(size: 28, name: 'Nimali P'),
            const SizedBox(width: 8),
            const TrustLevelBadge(trustLevel: 3),
            const SizedBox(width: 6),
            const AppTag('Request pending', tone: AppTone.warning),
          ],
        ),
      ],
    ),
  );

  Widget _verificationRows() => FlatCard(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
    child: Column(
      children: [
        for (final r in const [
          ('Phone', AppIcons.phone, AppTone.success, 'Verified'),
          ('LinkedIn', AppIcons.link, AppTone.accent, 'Verify'),
          ('Work email', AppIcons.mail, AppTone.accent, 'Verify'),
        ])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Row(
              children: [
                SquareIconTile(r.$2, tone: r.$3),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    r.$1,
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                AppTag(
                  r.$4,
                  tone: r.$4 == 'Verified' ? AppTone.success : AppTone.accent,
                ),
              ],
            ),
          ),
      ],
    ),
  );
}
