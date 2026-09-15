import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/models/public_profile.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/features/profile/public_profile_body.dart';

/// Shown when I'M INTERESTED is tapped, before anything is sent: who is
/// hosting — their profile, record and badges, and their recent meetups —
/// with the send as the one action at the bottom. A person deciding whether
/// to sit at a stranger's table should see the stranger first; a host's
/// profile is public to would-be joiners for exactly this reason.
///
/// Resolves true when the user confirms, false (or null) when they dismiss.
/// The caller sends the request; this sheet never does, so the existing
/// request/error handling stays where it is.
Future<bool> showJoinConfirmationSheet(
  BuildContext context, {
  required Meetup meetup,
}) async {
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppPalette.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _JoinConfirmationSheet(meetup: meetup),
  );
  return confirmed ?? false;
}

class _JoinConfirmationSheet extends ConsumerStatefulWidget {
  const _JoinConfirmationSheet({required this.meetup});

  final Meetup meetup;

  @override
  ConsumerState<_JoinConfirmationSheet> createState() =>
      _JoinConfirmationSheetState();
}

class _JoinConfirmationSheetState
    extends ConsumerState<_JoinConfirmationSheet> {
  // One fetch for the sheet's lifetime — see PublicProfilePage for why the
  // future is not created in build().
  late final Future<PublicProfile> _host = ref
      .read(authServiceProvider)
      .getPublicProfile(widget.meetup.hostUserId);

  @override
  Widget build(BuildContext context) {
    final meetup = widget.meetup;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.82,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppPalette.hairline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'YOUR HOST',
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.6,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${meetup.intentLabel} · ${meetup.formattedWindow}',
              style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: FutureBuilder<PublicProfile>(
                future: _host,
                builder: (context, snapshot) {
                  return ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                    children: [
                      if (snapshot.hasError)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text(
                            'Couldn\'t load the host\'s profile right now. '
                            'You can still send your request.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppPalette.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                        )
                      else
                        PublicProfileBody(
                          profile: snapshot.data,
                          fallbackName: meetup.hostFullName,
                          compact: true,
                        ),
                    ],
                  );
                },
              ),
            ),
            // Pinned below the scroll so it is reachable without reading to
            // the end — the sheet's one action.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PrimaryButton(
                    label: 'CONFIRM YOUR INTEREST',
                    onPressed: () => Navigator.of(context).pop(true),
                  ),
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(
                      'NOT NOW',
                      style: TextStyle(
                        color: AppPalette.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
