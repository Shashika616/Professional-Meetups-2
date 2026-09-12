import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/public_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/features/profile/public_profile_body.dart';

/// Another member, as a host or fellow participant is allowed to see them:
/// name, photo, trust level, record, which verifications they hold — as
/// badges, never the phone number or email behind them — and their recent
/// meetups. Built on [PublicProfile], which has no field for anything
/// more, so this screen cannot grow a leak by accident.
///
/// Who may open whom is decided server-side (a shared meetup as
/// host/accepted, or the member hosts one); a refusal arrives as
/// [ForbiddenActionException] and is shown as a state, not an error.
class PublicProfilePage extends ConsumerStatefulWidget {
  const PublicProfilePage({super.key, required this.userId, this.initialName});

  final String userId;

  /// The name the caller already had (from the request or participant
  /// row), shown in the header while the profile loads so the page does
  /// not open blank.
  final String? initialName;

  static Future<void> open(
    BuildContext context, {
    required String userId,
    String? initialName,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            PublicProfilePage(userId: userId, initialName: initialName),
      ),
    );
  }

  @override
  ConsumerState<PublicProfilePage> createState() => _PublicProfilePageState();
}

class _PublicProfilePageState extends ConsumerState<PublicProfilePage> {
  // Created once, here, not in build(): a future made inside build() is a
  // fresh network call on every rebuild — a theme change, a keyboard, a
  // parent setState — and this page has nothing that should refetch.
  late final Future<PublicProfile> _profile = ref
      .read(authServiceProvider)
      .getPublicProfile(widget.userId);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(title: const Text('MEMBER')),
      body: AppBackground(
        child: SafeArea(
          child: FutureBuilder<PublicProfile>(
            future: _profile,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                final error = snapshot.error;
                return _State(
                  icon: error is ForbiddenActionException
                      ? Icons.lock_outline_rounded
                      : Icons.cloud_off_rounded,
                  message: switch (error) {
                    ForbiddenActionException e => e.message,
                    SessionExpiredException _ =>
                      'Your session has expired. Please sign in again.',
                    _ => 'Couldn\'t load this member right now.',
                  },
                );
              }
              return ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                children: [
                  PublicProfileBody(
                    profile: snapshot.data,
                    fallbackName: widget.initialName,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _State extends StatelessWidget {
  const _State({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: AppPalette.textSecondary),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppPalette.textSecondary, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
