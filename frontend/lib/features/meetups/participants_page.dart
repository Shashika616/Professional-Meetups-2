import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';
import 'package:professional_connections_platform/features/meetups/widgets/participants_strip.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

/// The full attendee list.
///
/// Below trust level 2 this shows the right NUMBER of people with no
/// identities, because that is exactly what the server sent — see
/// [ParticipantsStrip] and the backend's ListMeetupParticipants for why the
/// redaction happens there and not here.
class ParticipantsPage extends ConsumerStatefulWidget {
  const ParticipantsPage({super.key, required this.meetupId});

  final String meetupId;

  static Future<void> open(BuildContext context, {required String meetupId}) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ParticipantsPage(meetupId: meetupId)),
    );
  }

  @override
  ConsumerState<ParticipantsPage> createState() => _ParticipantsPageState();
}

class _ParticipantsPageState extends ConsumerState<ParticipantsPage> {
  MeetupParticipants? _data;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await ref
          .read(meetupServiceProvider)
          .listMeetupParticipants(widget.meetupId);
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } on MeetupSessionExpiredException {
      // A 401 means the session itself is gone, so every later call
      // fails too. Falling through to the generic catch below would
      // show an error the user can only retry forever; signing out is
      // the only thing that recovers. Mirrors the AuthService
      // SessionExpiredException idiom in profile_page.dart.
      if (mounted) {
        ref.read(authSessionProvider.notifier).forceSignOut();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          iconTheme: IconThemeData(color: AppPalette.textPrimary),
          title: Text(
            'WHO\'S COMING',
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 14,
              letterSpacing: 2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        body: SafeArea(top: false, child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: SkeletonLoader(child: _ParticipantsSkeleton()),
      );
    }
    final data = _data;
    if (_error != null || data == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 40,
                color: AppPalette.textSecondary,
              ),
              const SizedBox(height: 12),
              Text(
                "Couldn't load who's coming.",
                style: TextStyle(color: AppPalette.textSecondary),
              ),
              const SizedBox(height: 16),
              PrimaryButton(
                label: 'TRY AGAIN',
                height: 44,
                onPressed: () {
                  setState(() {
                    _loading = true;
                    _error = null;
                  });
                  _load();
                },
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        Text(
          data.totalCount == 1 ? '1 person' : '${data.totalCount} people',
          style: TextStyle(
            color: AppPalette.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 16),
        // The upsell goes ABOVE the list, not over it as a paywall overlay:
        // the placeholder rows below are real information (how many, and
        // which one hosts), and covering them would withhold what the viewer
        // is actually allowed to know.
        if (data.redacted) ...[
          const _VerifyToSeeNotice(),
          const SizedBox(height: 16),
        ],
        for (final participant in data.participants)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _ParticipantRow(
              participant: participant,
              redacted: data.redacted,
            ),
          ),
      ],
    );
  }
}

class _VerifyToSeeNotice extends StatelessWidget {
  const _VerifyToSeeNotice();

  @override
  Widget build(BuildContext context) {
    return FlatCard(
      radius: 12,
      tint: AppPalette.candyBlue.withValues(alpha: 0.07),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 17,
                color: AppPalette.candyBlue,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Verify to see who’s coming',
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Names and photos are only shared with verified members — the '
            'same protection everyone here gets.',
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 12.5),
          ),
          const SizedBox(height: 14),
          PrimaryButton(
            label: 'GET VERIFIED',
            height: 44,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const VerificationChecklistPage(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ParticipantRow extends StatelessWidget {
  const _ParticipantRow({required this.participant, required this.redacted});

  final MeetupParticipant participant;
  final bool redacted;

  @override
  Widget build(BuildContext context) {
    return FlatCard(
      radius: 12,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          if (redacted)
            const RedactedFace(size: 38)
          else
            ProfessionalAvatar(
              name: participant.fullName,
              imageUrl: participant.profilePhotoUrl.isEmpty
                  ? null
                  : participant.profilePhotoUrl,
              size: 38,
            ),
          const SizedBox(width: 12),
          Expanded(
            child: redacted
                // A grey bar, not a fake name: inventing placeholder text
                // ("Member") would read as someone's actual display name.
                ? Container(
                    height: 11,
                    width: 128,
                    decoration: BoxDecoration(
                      color: AppPalette.textSecondary.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        participant.fullName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppPalette.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Level ${participant.trustLevel}',
                        style: TextStyle(
                          color: AppPalette.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
          ),
          // The host stays labelled even when redacted — knowing a meetup
          // has a host is not the same as knowing who they are.
          if (participant.isHost)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppPalette.candyBlue.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'HOST',
                style: TextStyle(
                  color: AppPalette.candyBlue,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ParticipantsSkeleton extends StatelessWidget {
  const _ParticipantsSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget box(double h, {double? w}) => Container(
      height: h,
      width: w,
      decoration: BoxDecoration(
        color: AppPalette.card,
        borderRadius: BorderRadius.circular(12),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        box(22, w: 110),
        const SizedBox(height: 18),
        for (var i = 0; i < 4; i++) ...[box(66), const SizedBox(height: 10)],
      ],
    );
  }
}
