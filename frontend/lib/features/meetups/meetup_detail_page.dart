import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/analytics/analytics.dart';
import 'package:professional_connections_platform/core/analytics/event_names.g.dart';
import 'package:professional_connections_platform/core/analytics/screen_names.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_dialog.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/app_tag.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/load_failed_state.dart';
import 'package:professional_connections_platform/features/meetups/widgets/join_confirmation_sheet.dart';
import 'package:professional_connections_platform/features/meetups/widgets/other_meetups_nearby.dart';
import 'package:professional_connections_platform/features/meetups/widgets/schedule_conflict_sheet.dart';
import 'package:professional_connections_platform/features/profile/public_profile_page.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';
import 'package:professional_connections_platform/features/home/widgets/meetup_card.dart'
    show LockedCardHeader;
import 'package:professional_connections_platform/features/meetups/events_page.dart'
    show RequestManagementPage;
import 'package:professional_connections_platform/features/meetups/location_view_page.dart';
import 'package:professional_connections_platform/features/meetups/widgets/host_meetup_controls.dart';
import 'package:professional_connections_platform/features/meetups/review/meetup_review_section.dart';
import 'package:professional_connections_platform/features/meetups/widgets/participants_strip.dart';
import 'package:professional_connections_platform/features/meetups/widgets/rating_prompt.dart';
import 'package:professional_connections_platform/features/meetups/widgets/share_with_contacts_sheet.dart';
import 'package:professional_connections_platform/features/verification/verification_checklist_page.dart';

part 'meetup_detail_actions.dart';
part 'meetup_detail_sections.dart';
part 'meetup_detail_dialogs.dart';

/// Replaces `UpcomingMeetupCard`'s hardcoded "Coffee with Sachini Fernando"
/// text and its two stub taps with a real detail page bound to real
/// [Meetup] data, including the Safety Gate sub-flow (ADR-013 § 3,
/// frontend/meetup-scheduling-PLAN.md Step 9).
class MeetupDetailPage extends ConsumerStatefulWidget {
  const MeetupDetailPage({super.key, required this.meetupId});

  final String meetupId;

  @override
  ConsumerState<MeetupDetailPage> createState() => _MeetupDetailPageState();
}

class _MeetupDetailPageState extends ConsumerState<MeetupDetailPage> {
  Meetup? _meetup;
  SafetyState? _safetyState;
  bool _loading = true;
  Object? _loadError;

  /// Set once the viewer confirms (SubmitMeetupFeedback, happened=true)
  /// that this meetup happened — one of three triggers for mounting
  /// [RatingPrompt] fresh so its own initState fetch runs exactly when
  /// eligibility just changed, rather than rendering it unconditionally
  /// from page load and leaving it stuck with a stale empty fetch (ADR-020
  /// §4 widens the other two triggers — see [_buildContent]).

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final meetup = await ref
          .read(meetupServiceProvider)
          .getMeetup(widget.meetupId);
      SafetyState? safetyState;
      // Always attempt the fetch now (ADR-024 §2) — the host's own Safety
      // Gate row is created at meetup creation, independent of
      // acceptedCount, so gating this on "at least one accepted request"
      // would hide it from the host of a brand-new meetup with zero
      // accepted requests yet. GetSafetyState now enforces per-caller
      // participation server-side (ADR-024 §3): a caller who is neither
      // this meetup's host nor an accepted requester on it gets
      // MeetupForbiddenException — not a real error to surface, it just
      // means there's nothing here for this viewer (a non-participant
      // browsing someone else's meetup detail page, which this app's own
      // navigation doesn't normally do, but the backend enforces either
      // way). MeetupNotFoundException is kept defensively — the backend no
      // longer returns it for GetSafetyState, but treating it the same way
      // costs nothing and guards against drift.
      try {
        safetyState = await ref
            .read(meetupServiceProvider)
            .getSafetyState(widget.meetupId);
      } on MeetupForbiddenException {
        // not a participant — safetyState stays null, section stays hidden.
      } on MeetupNotFoundException {
        // not started yet — safetyState stays null.
      }
      if (!mounted) return;
      setState(() {
        _meetup = meetup;
        _safetyState = safetyState;
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
        // The error itself, so the failure state can tell offline from
        // the rest.
        _loadError = error;
        _loading = false;
      });
    }
  }

  Future<void> _acknowledgeChecklist() async {
    try {
      final state = await ref
          .read(meetupServiceProvider)
          .acknowledgeSafetyChecklist(widget.meetupId);
      if (!mounted) return;
      setState(() => _safetyState = state);
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
      if (mounted) {
        showSnack(
          context,
          error is MeetupException
              ? error.message
              : 'Something went wrong. Please try again.',
          type: ToastType.error,
        );
      }
    }
  }

  /// Opens the contact picker and, if the user confirms, tells the chosen
  /// contacts where and when this meetup is.
  ///
  /// REPLACES a "Share live location" switch that wrote a boolean nothing
  /// read — it told the user their location was being shared and shared it
  /// with nobody. The recipients are the user's own emergency contacts, not
  /// the host: telling the person you are meeting where you are is not a
  /// safety feature.
  Future<void> _shareWithContacts() async {
    final already = _safetyState?.sharedWithContactIds.toSet() ?? <String>{};
    final picked = await showShareWithContactsSheet(
      context,
      alreadyShared: already,
    );
    if (picked == null || picked.isEmpty || !mounted) return;

    try {
      final state = await ref
          .read(meetupServiceProvider)
          .shareWithContacts(widget.meetupId, picked);
      if (!mounted) return;
      setState(() => _safetyState = state);
      showSnack(
        context,
        picked.length == 1
            ? 'Your contact has been told.'
            : '${picked.length} contacts have been told.',
        type: ToastType.success,
      );
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
      if (mounted) {
        showSnack(
          context,
          error is MeetupException
              ? error.message
              : 'Something went wrong. Please try again.',
          type: ToastType.error,
        );
      }
    }
  }

  /// Whether the viewer was actually ON this meetup.
  ///
  /// [_isPastMeetup] answers "is this over", which is a question about the
  /// CLOCK. It says nothing about the viewer, and for a while this page
  /// treated the two as the same question: the review section was gated on
  /// `_isPastMeetup` alone, so any authenticated user who opened any finished
  /// meetup from the browse list was invited to review it. Reported from the
  /// deployed app by someone who had never requested to join.
  ///
  /// The server was never fooled - SubmitMeetupReview calls requireParticipant
  /// and ListRatableParticipants hands a non-participant an empty roster - so
  /// nothing false could be written. What was broken was the offer: a control
  /// that cannot work, on a meetup that is none of your business.
  ///
  /// Mirrors the server's own definition of a participant deliberately (host,
  /// or an ACCEPTED requester). Pending is not enough: a request that was
  /// never answered before the meetup ended means the person did not go.
  bool get _viewerIsParticipant {
    final meetup = _meetup;
    if (meetup == null) return false;
    return meetup.isHostedByMe ||
        meetup.myRequestStatus == MeetupRequestStatus.accepted;
  }

  @override
  Widget build(BuildContext context) {
    // Pushed as its own route from Home/Matches, not one of AppShell's
    // bottom-nav tabs — see EventsPage's matching comment for why this
    // needs its own AppBackground wrap rather than inheriting AppShell's.
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Meetup')),
        body: SafeArea(
          child: _loading
              ? const _MeetupDetailSkeleton()
              : _loadError != null
              ? SkeletonThenFailure(
                  skeleton: const _MeetupDetailSkeleton(),
                  failure: ListView(
                    children: [
                      LoadFailedState(
                        failure: LoadFailure.of(_loadError),
                        onRetry: _load,
                      ),
                    ],
                  ),
                )
              : _buildContent(context, _meetup!),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, Meetup meetup) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        // THE HERO IS THE PHOTO NOW (screen set: "Meetup detail")
        //
        // This was one card with [IntentBackdrop] behind it — the intent's
        // photo at low opacity under the text, which at that strength read
        // as a smudge rather than as a picture of the kind of thing this
        // is. The screen set puts the photo up front: a 112px band with a
        // scrim, the intent tag, the time and the place over it, and the
        // host moved out into its own card underneath.
        //
        // Nothing below the hero changed: same host row, same confirmed
        // count, same ParticipantsStrip, same locked handling.
        _DetailHero(meetup: meetup),
        const SizedBox(height: 14),
        FlatCard(
          radius: 22,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // lockedForViewer (ADR-028, round-5 hardening) — GetMeetup
              // now redacts the same way ListOpenMeetups does, so
              // hostFullName/locationLabel/the window can genuinely be
              // absent here. Reuses the shared LockedCardHeader
              // rather than a second lock-treatment widget. Currently
              // unreachable through any in-app navigation path (a locked
              // card's tap redirects at the card level, never opening this
              // page) — handled anyway so this doesn't force-unwrap into a
              // crash the moment that stops being true (e.g. a
              // notification deep link).
              if (meetup.lockedForViewer)
                LockedCardHeader(locationLabel: meetup.locationLabel)
              else ...[
                // The window and the address are on the hero now;
                // repeating them here was the first thing that
                // looked wrong once the photo moved up.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => PublicProfilePage.open(
                    context,
                    userId: meetup.hostUserId,
                    initialName: meetup.hostFullName,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          'Hosted by ${meetup.hostFullName!} • L${meetup.hostTrustLevel} Trust',
                          style: TextStyle(
                            color: AppPalette.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      AppIcon(
                        AppIcons.forward,
                        size: 16,
                        color: AppPalette.textSecondary,
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 4),
              // accepted_count/capacity are never redacted (ADR-028 § 1).
              Text(
                '${meetup.acceptedCount}/${meetup.capacity} confirmed',
                style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
              ),
              // Who is actually coming, on the card itself. Self-hides when
              // there is nobody but the host and nothing to show. Identities
              // are withheld server-side below trust level 2 — see
              // ParticipantsStrip.
              const SizedBox(height: 12),
              Divider(height: 1, color: AppPalette.hairline),
              const SizedBox(height: 12),
              ParticipantsStrip(
                meetupId: widget.meetupId,
                meetup: meetup,
                finished:
                    meetup.status == MeetupStatus.completed || _isPastMeetup,
              ),
            ],
          ),
        ),
        if (meetup.status == MeetupStatus.cancelled) ...[
          const SizedBox(height: 14),
          _CancelledBanner(reason: meetup.cancellationReason ?? ''),
        ],
        const SizedBox(height: 14),
        // Two peers, side by side, not a stack of full width outlines.
        //
        // These were 40pt hairline-bordered bars spanning the page, one above
        // the other, which read as disabled rows rather than as things to
        // press. They are the same KIND of action as each other and neither is
        // the page's main one, so they belong on one line sharing the width,
        // with an icon each to make them scannable without reading.
        //
        // ADR-029 (round-8 hardening) — LocationViewPage.open owns the gate
        // itself (toast + redirect), so its button is shown regardless of
        // hosting/request state and regardless of trust level. The trust level
        // is passed rather than re-derived there: this page already has it,
        // and a widget that navigates should not be reaching into the session
        // to decide whether it may.
        // The participants strip on the card above is the way into the
        // guest list — a second PARTICIPANTS tile here did the same thing.
        _ActionTile(
          icon: AppIcons.map,
          label: 'Location',
          detail: 'Map, address and directions',
          onTap: () => LocationViewPage.open(
            context,
            meetup,
            viewerTrustLevel: ref.watch(
              authSessionProvider.select(
                (s) => s.value?.profile?.trustLevel ?? 0,
              ),
            ),
          ),
        ),
        // The host's way into their request list from here. Hosts reach this
        // page from the Home card and from notifications, and before this
        // tile their only route to the requests was back out to the Events
        // tab. Live meetups only: a finished one has nothing left to manage.
        if (meetup.isHostedByMe && !_isPastMeetup) ...[
          const SizedBox(height: 12),
          _ActionTile(
            icon: AppIcons.people,
            label: 'View requests',
            detail: 'See who asked to join, accept or pass',
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  settings: const RouteSettings(
                    name: ScreenNames.requestManagement,
                  ),
                  builder: (_) => RequestManagementPage(meetup: meetup),
                ),
              );
              // Accepting or rejecting over there changes what this page
              // shows (counts, participants), so reload on the way back.
              if (mounted) _load();
            },
          ),
        ],
        const SizedBox(height: 12),
        // Everything from here down is about GETTING to a meetup. A finished
        // one gets the review instead — see _isPastMeetup.
        if (_isPastMeetup) ...[
          // Non-participants get NOTHING here, not a disabled review: the
          // join/withdraw controls in the else-branch are equally wrong for a
          // finished meetup, so a stranger viewing one correctly sees the
          // details and nothing actionable.
          if (_viewerIsParticipant)
            MeetupReviewSection(
              meetupId: widget.meetupId,
              hostUserId: meetup.hostUserId,
              cancelled: meetup.status == MeetupStatus.cancelled,
              cancellationReason: meetup.cancellationReason,
              viewerIsHost: meetup.isHostedByMe,
            ),
        ] else ...[
          if (!meetup.isHostedByMe && meetup.myRequestStatus == null)
            _buildJoinAction(context, meetup)
          else if (!meetup.isHostedByMe && meetup.myRequestStatus != null) ...[
            _RequestStatusBanner(status: meetup.myRequestStatus!),
            // A turned-down requester is handed the next step on the same
            // screen, before the page can read as a dead end. Only while
            // the meetup is still ahead: for a finished one there is
            // nothing to redirect from.
            if (meetup.myRequestStatus == MeetupRequestStatus.rejected) ...[
              const SizedBox(height: 20),
              OtherMeetupsNearby(
                excludeMeetupId: meetup.id,
                onOpen: (other) => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    settings: const RouteSettings(
                      name: ScreenNames.meetupDetail,
                    ),
                    builder: (_) => MeetupDetailPage(meetupId: other.id),
                  ),
                ),
              ),
            ],
            if (_canWithdraw(meetup)) ...[
              const SizedBox(height: 10),
              // Before the host answers, taking the request back is a
              // cancellation; after acceptance it is a withdrawal. Both
              // undo the viewer's own standing on this meetup, so both are
              // outlined in red, but the cancellation in the SOFTER red
              // (the cancelled-meetup tone, with the border further eased):
              // nothing is broken and nobody is let down, so it must not
              // shout the way the withdrawal does.
              if (meetup.myRequestStatus == MeetupRequestStatus.pending)
                SecondaryButton(
                  label: 'Cancel request',
                  height: 40,
                  color: AppPalette.cancelled,
                  borderColor: AppPalette.cancelled.withValues(alpha: 0.55),
                  onPressed: () =>
                      _confirmWithdraw(meetup.myRequestId!, pending: true),
                )
              else
                SecondaryButton(
                  label: 'Withdraw request',
                  height: 40,
                  color: AppPalette.danger,
                  borderColor: AppPalette.danger,
                  onPressed: () =>
                      _confirmWithdraw(meetup.myRequestId!, pending: false),
                ),
            ],
          ],
          // Host-only Cancel/Close actions (ADR-016 + its 2026-08-20
          // addendum) — extracted into one shared widget, also used by the
          // "Hosting" tab's request-management screen, so this logic exists
          // once. Independent of the Safety Gate section below (rating
          // eligibility stays gated on each participant's own
          // confirmed-attendance feedback, ADR-015, unaffected by either
          // action).
          HostMeetupControls(
            meetup: meetup,
            onChanged: (updated) => setState(() => _meetup = updated),
          ),
          // Gated on whether *this viewer's own* Safety Gate row was actually
          // fetched (ADR-024 §2/§3), not meetup.acceptedCount > 0 — the host's
          // row exists from meetup creation, before any request is accepted,
          // and a non-participant now correctly never gets one at all.
          if (_safetyState != null) ...[
            const SizedBox(height: 24),
            _SafetyGateSection(
              safetyState: _safetyState,
              onAcknowledgeChecklist: _acknowledgeChecklist,
              onShareWithContacts: _shareWithContacts,
            ),
          ],
          // ADR-020 widens this beyond the original happened-based trigger:
          // a cancelled meetup makes a previously-accepted requester eligible
          // to rate the host, and a host is always worth checking since a
          // withdrawn requester becomes ratable independent of the meetup's
          // own status/window. RatingPrompt itself self-gates on whatever
          // ListRatableParticipants actually returns, rendering nothing if
          // there's still nothing to rate.
          // _feedbackHappened used to be the first term here. It was set by
          // the IT HAPPENED button and by nothing else, so with that prompt
          // removed it could never become true again and the condition was
          // exactly what is left below. Dropping a provably-false term is
          // behaviour preserving; leaving a flag that can never flip is not.
          //
          // A participant of a finished meetup still reaches rating, through
          // MeetupReviewSection further up this page rather than through a
          // confirmation prompt.
          if (meetup.status == MeetupStatus.cancelled ||
              meetup.isHostedByMe) ...[
            const SizedBox(height: 24),
            RatingPrompt(meetupId: widget.meetupId),
          ],
        ],
      ],
    );
  }
}
