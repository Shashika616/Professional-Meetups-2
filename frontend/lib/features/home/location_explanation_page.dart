import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/analytics/screen_names.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';

/// What the app wants location for, before the system asks (plan 3.3).
/// Answers true for Continue, which leads to the system prompt, and false
/// for Not now or the back button, which asks nothing.
class LocationExplanationPage extends StatelessWidget {
  const LocationExplanationPage({super.key});

  static Future<bool> show(BuildContext context) async =>
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          settings: const RouteSettings(name: ScreenNames.locationExplanation),
          fullscreenDialog: true,
          builder: (_) => const LocationExplanationPage(),
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: AppIcon(
                  AppIcons.locate,
                  size: 40,
                  color: AppPalette.candyBlue,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Find meetups near you',
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'TieHere uses your location while you use the app, to show '
                'meetups within 50 km and to check you are nearby when you '
                'ask to join. We store it rounded to about 100 metres.',
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 15,
                  height: 1.45,
                ),
              ),
              const Spacer(flex: 2),
              PrimaryButton(
                label: 'Continue',
                onPressed: () => Navigator.of(context).pop(true),
              ),
              const SizedBox(height: 10),
              SecondaryButton(
                label: 'Not now',
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
