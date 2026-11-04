import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:professional_connections_platform/core/config/update_required.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';

const _playUrl =
    'https://play.google.com/store/apps/details?id=com.profconn.professional_connections_platform';
const _appStoreUrl = 'https://apps.apple.com/search?term=TieHere';

/// Replaces the whole app with [UpdateRequiredPage] when this build is below
/// the server's `min_supported_app_version`, or the server answered 426
/// (N1-D3, N1-D4). Checked at start and on every return to the foreground.
///
/// The app is replaced rather than covered, so there is nothing behind the
/// screen to reach with the back button.
class UpdateGate extends ConsumerStatefulWidget {
  const UpdateGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends ConsumerState<UpdateGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ref.invalidate(appConfigProvider);
  }

  @override
  Widget build(BuildContext context) {
    final minimum = ref.watch(
      appConfigProvider.select((c) => c.value?.minSupportedAppVersion ?? ''),
    );
    return ValueListenableBuilder<bool>(
      valueListenable: UpdateRequired.signalled,
      builder: (context, signalled, child) =>
          signalled || isBelowMinimumVersion(minimum)
          ? const UpdateRequiredPage()
          : child!,
      child: widget.child,
    );
  }
}

class UpdateRequiredPage extends StatelessWidget {
  const UpdateRequiredPage({super.key, this.open});

  /// Opens the store; replaced in tests.
  final Future<void> Function(Uri uri)? open;

  Future<void> _openStore() async {
    final android = defaultTargetPlatform == TargetPlatform.android;
    final uri = Uri.parse(android ? _playUrl : _appStoreUrl);
    final launch =
        open ?? (Uri u) => launchUrl(u, mode: LaunchMode.externalApplication);
    await launch(uri);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppPalette.onyx,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppIcon(AppIcons.bell, size: 40, color: AppPalette.candyBlue),
              const SizedBox(height: 20),
              Text(
                'Update TieHere',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'This version is no longer supported. Update to keep using '
                'the app.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 28),
              PrimaryButton(label: 'Update', onPressed: _openStore),
            ],
          ),
        ),
      ),
    );
  }
}
