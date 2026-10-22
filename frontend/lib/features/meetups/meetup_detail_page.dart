import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  Future<void> _requestToJoin() async {
    try {
      await ref.read(meetupServiceProvider).requestToJoin(widget.meetupId);
      if (!mounted) return;
      showSnack(context, 'Request sent.', type: ToastType.success);
      await _load();
    } on MeetupSessionExpiredException {
      // A 401 means the session itself is gone, so every later call
      // fails too. Falling through to the generic catch below would
      // show an error the user can only retry forever; signing out is
      // the only thing that recovers. Mirrors the AuthService
      // SessionExpiredException idiom in profile_page.dart.
      if (mounted) {
        ref.read(authSessionProvider.notifier).forceSignOut();
      }
    } on MeetupScheduleConflictException catch (error) {
      // Already committed elsewhere in this window — see the sheet.
      if (mounted) await showScheduleConflictSheet(context, error: error);
    } on MeetupForbiddenException catch (error) {
      // The server's trust gate: the button's own check uses the profile
      // in memory, which can lag a verification. Same destination as the
      // locked button.
      if (!mounted) return;
      showSnack(context, error.message, type: ToastType.locked);
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const VerificationChecklistPage()),
      );
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

  /// Requester-side withdraw (ADR-020 §4) — both pending and accepted
  /// requests are withdrawable. The note is optional context shown to the
  /// host, who may rate the requester once for the withdrawal.
  /// Two different things, one endpoint (the server tells them apart by
  /// the request's state, and so does this):
  ///
  ///  - A PENDING request is CANCELLED: the host has not answered, nobody
  ///    is told, nothing is recorded, and the user may ask again. A plain
  ///    yes/no — there is no host to leave a note for.
  ///  - An ACCEPTED request is WITHDRAWN (ADR-020 §4): the host planned
  ///    around this person and is told who backed out, with an optional
  ///    note. That is the dialog with the text field.
  Future<void> _confirmWithdraw(
    String requestId, {
    required bool pending,
  }) async {
    final String? note;
    if (pending) {
      final confirmed = await showAppDialog<bool>(
        context,
        builder: (context) => const _CancelRequestDialog(),
      );
      if (confirmed != true) return;
      note = '';
    } else {
      note = await showAppDialog<String>(
        context,
        // Returns null on BACK/dismiss, or the (possibly empty) note text
        // on WITHDRAW — a plain bool wouldn't carry the note back out, so
        // the dialog itself resolves the confirm/note-capture into one
        // value.
        builder: (context) => const _WithdrawNoteDialog(),
      );
      if (note == null) return;
    }
    if (!mounted) return;
    try {
      await ref
          .read(meetupServiceProvider)
          .withdrawRequest(requestId, note: note.isEmpty ? null : note);
      if (!mounted) return;
      showSnack(
        context,
        pending ? 'Request cancelled.' : 'Request withdrawn.',
        type: ToastType.success,
      );
      await _load();
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

  /// Redirects a Level-0 (or otherwise under-trust) tap to the ADR-028
  /// checklist instead of letting it reach the server just to bounce off
  /// its 403 — mirrors the browse card's own gate (ADR-014's Level
  /// 0 read-only audit, Step 6, updated by ADR-028 § 2). Checks both
  /// signals: `meetup.lockedForViewer` (server-authoritative — `GetMeetup`
  /// redacts too as of round-5 hardening) and the client-side
  /// `canJoin` fallback, since a directly-fetched meetup this page's
  /// own viewer legitimately unlocked will have `lockedForViewer: false`
  /// either way, but the client check stays as defense-in-depth for
  /// anything that ever reaches this page without going through a real
  /// `GetMeetup` round trip. In practice a locked meetup's card no longer
  /// navigates here at all (ADR-028 § 2's toast-and-redirect happens at
  /// the card level), so this is a defensive fallback path (e.g. a
  /// notification deep link), not the primary one. The server-side check
  /// in `services/meetup/internal/service/trustgate.go` remains the one
  /// that's actually enforced; this is UX only, same discipline as
  /// ADR-013.
  Widget _buildJoinAction(BuildContext context, Meetup meetup) {
    final trustLevel = ref.watch(
      authSessionProvider.select((s) => s.value?.profile?.trustLevel ?? 0),
    );
    if (!meetup.lockedForViewer && meetup.intent.canJoin(trustLevel)) {
      return PrimaryButton(
        label: 'I\'m interested',
        onPressed: () async {
          // Who is hosting, before anything is sent.
          if (!await showJoinConfirmationSheet(context, meetup: meetup)) {
            return;
          }
          await _requestToJoin();
        },
      );
    }
    return PrimaryButton(
      label: 'I\'m interested',
      onPressed: () {
        showSnack(
          context,
          meetup.intent.joinLockedMessage,
          type: ToastType.locked,
        );
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const VerificationChecklistPage()),
        );
      },
    );
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

  /// Both pending and accepted requests are withdrawable (ADR-020 §4,
  /// mirrors the backend's own widened precondition) — [myRequestId] is
  /// only ever set alongside [myRequestStatus], but the null-check is kept
  /// explicit since [SecondaryButton.onPressed] needs a non-null id to
  /// call.
  bool _canWithdraw(Meetup meetup) =>
      meetup.myRequestId != null &&
      (meetup.myRequestStatus == MeetupRequestStatus.pending ||
          meetup.myRequestStatus == MeetupRequestStatus.accepted);

  /// Whether this meetup is finished — over, or called off.
  ///
  /// A finished meetup is a different page. Everything below VIEW LOCATION
  /// on the live page exists to help someone GET to a meetup — the Safety
  /// Gate, check-in, withdraw, the host's cancel/close controls — and none
  /// of it means anything once the meetup has happened. Showing it anyway
  /// was offering a "WITHDRAW REQUEST" for an evening that already
  /// finished.
  ///
  /// What replaces it is the review: the flow if it is still owed, the
  /// scores themselves once it is done. That also makes this page the place
  /// a review stays reachable after the home card's 14-day window lapses —
  /// without it, an unreviewed meetup would become permanently unreviewable.
  bool get _isPastMeetup {
    final meetup = _meetup;
    if (meetup == null) return false;
    if (meetup.status == MeetupStatus.cancelled) return true;
    final windowEnd = meetup.windowEnd;
    return windowEnd != null && DateTime.now().isAfter(windowEnd);
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

/// Shown while [MeetupService.getMeetup] resolves — mirrors the summary
/// card + action button shape `_buildContent` renders once data actually
/// arrives, instead of a bare spinner.
class _MeetupDetailSkeleton extends StatelessWidget {
  const _MeetupDetailSkeleton();

  @override
  Widget build(BuildContext context) =>
      SkeletonLoader(child: _content(context));

  /// The placeholder shapes themselves. [SkeletonLoader] above adds the
  /// delay-before-showing and the shimmer sweep, so every caller of this
  /// widget gets both without knowing about either.
  Widget _content(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        FlatCard(
          radius: 18,
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SkeletonBox(width: 70, height: 11, opacity: 0.08),
              const SizedBox(height: 10),
              const SkeletonBox(width: 140, height: 20, opacity: 0.08),
              const SizedBox(height: 8),
              const SkeletonBox(width: 180, height: 13),
              const SizedBox(height: 14),
              const SkeletonBox(width: 160, height: 12),
              const SizedBox(height: 4),
              const SkeletonBox(width: 100, height: 12),
            ],
          ),
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) =>
              SkeletonBox(width: constraints.maxWidth, height: 48, radius: 14),
        ),
      ],
    );
  }
}

/// Where the viewer's request stands. A STATE, not a control: it is
/// left-aligned with an icon and a sentence, carries no press affordance,
/// and is coloured by outcome (amber while waiting, green when in, blue
/// when not this time, grey when withdrawn), so it cannot be mistaken for the
/// LOCATION button above it or the cancel/withdraw button below it.
class _RequestStatusBanner extends StatelessWidget {
  const _RequestStatusBanner({required this.status});

  final MeetupRequestStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, detail, icon, color) = switch (status) {
      MeetupRequestStatus.pending => (
        'Request pending',
        'Waiting for the host to respond. We will notify you.',
        AppIcons.hourglass,
        AppPalette.gold,
      ),
      MeetupRequestStatus.accepted => (
        'You\'re in',
        'The host accepted your request. See you there.',
        AppIcons.checkCircle,
        AppPalette.verified,
      ),
      // Not red and not "declined": hosts keep groups small, so a no is
      // about fit, and the section under this banner points at what is
      // next.
      MeetupRequestStatus.rejected => (
        'Not this time',
        'Hosts keep their groups small, so not every request can fit. '
            'There are more meetups near you.',
        AppIcons.explore,
        AppPalette.candyBlue,
      ),
      MeetupRequestStatus.withdrawn => (
        'Withdrawn',
        'You left this meetup.',
        AppIcons.undo,
        AppPalette.textSecondary,
      ),
    };
    return Semantics(
      // Read as a status line, never announced as a button.
      liveRegion: true,
      label: '$label. $detail',
      child: FlatCard(
        radius: 18,
        padding: EdgeInsets.zero,
        tint: color.withValues(alpha: 0.08),
        border: color.withValues(alpha: 0.30),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The stripe went with the rest of them. This banner is
                // already tinted AND bordered in the state colour and
                // leads with a state icon in it; a fourth copy of the
                // same signal down the edge added nothing.
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 0, 12),
                  child: AppIcon(icon, size: 22, color: color),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.3,
                            fontSize: 11.5,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          detail,
                          style: TextStyle(
                            color: AppPalette.textSecondary,
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The Safety Gate sub-flow: the checklist, then telling a trusted contact.
///
/// It used to run checklist -> live-location -> check-in -> post-meetup
/// feedback. The last two are gone: they asked the user to confirm things the
/// app cannot verify, and between them the page asked about one meeting three
/// times. What remains is the half that does something FOR the user rather
/// than asking something OF them.
///
/// Backing out is not lost with them: WITHDRAW REQUEST above handles it, and
/// handles it properly, since a withdrawal actually leaves the meetup and
/// tells the host. DECLINE only ever wrote a safety flag.
class _SafetyGateSection extends StatelessWidget {
  const _SafetyGateSection({
    required this.safetyState,
    required this.onAcknowledgeChecklist,
    required this.onShareWithContacts,
  });

  final SafetyState? safetyState;

  final VoidCallback onAcknowledgeChecklist;
  final VoidCallback onShareWithContacts;

  @override
  Widget build(BuildContext context) {
    final acknowledged = safetyState?.checklistAcknowledged ?? false;
    final sharedCount = safetyState?.sharedWithContactIds.length ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Safety gate',
          style: TextStyle(
            color: AppPalette.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 12),
        FlatCard(
          radius: 18,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Before you go',
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 8),
              const _ChecklistItem('Meet in a public place'),
              const _ChecklistItem(
                'Tell a trusted contact where you\'re going',
              ),
              const _ChecklistItem('Keep first meetings short'),
              const _ChecklistItem('Never share OTP codes or send money'),
              const SizedBox(height: 12),
              if (!acknowledged)
                PrimaryButton(
                  label: 'I understand',
                  height: 44,
                  onPressed: onAcknowledgeChecklist,
                )
              else
                const _DoneRow('Checklist acknowledged'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // WAS a "Share live location" switch bound to a boolean nothing
        // read — the app said it was sharing the user's location and shared
        // it with nobody. Now a real action, and the copy says exactly what
        // the recipient gets rather than implying tracking.
        FlatCard(
          radius: 18,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tell a trusted contact',
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Send someone you trust the time and place of this meetup.',
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              // Confirmation of what was actually done. The whole reason the
              // share is persisted server-side is so this can be shown on a
              // later visit.
              if (sharedCount > 0) ...[
                _DoneRow(
                  sharedCount == 1
                      ? 'Told 1 trusted contact'
                      : 'Told $sharedCount trusted contacts',
                ),
                const SizedBox(height: 10),
              ],
              // Accent on the label and the border so it reads as the
              // action it is, not as a caption under the card's copy.
              SecondaryButton(
                label: sharedCount > 0 ? 'Tell someone else' : 'Tell someone',
                icon: AppIcons.share,
                height: 44,
                color: AppPalette.candyBlue,
                borderColor: AppPalette.candyBlue.withValues(alpha: 0.6),
                onPressed: onShareWithContacts,
              ),
            ],
          ),
        ),
        // The CHECK IN card and the "How did it go?" prompt used to sit here.
        //
        // Both removed on request. Check-in asked the user to confirm they had
        // arrived somewhere the app cannot verify, and the happened/didn't
        // happen prompt asked the same question a second time from the other
        // end. Neither gated anything a user could not do anyway, and together
        // they made the page ask three times about one meeting.
        //
        // What is NOT removed: the checklist above and the trusted-contact
        // card. Those do something for the user rather than asking something
        // of them.
      ],
    );
  }
}

/// A square-ish tappable tile: icon above a short label.
///
/// Deliberately not [SecondaryButton]. That widget is a wide, quiet bar built
/// for one full-width action at the bottom of a form; used twice in a row for
/// two peer actions it reads as a list of disabled rows. This has a filled
/// surface, a real border and an icon, so it looks like something you press.
/// The cancellation, on the meetup's own page: the state and the host's
/// words. Same soft red as the card edge; the reason quoted because it is
/// the host's, not the app's.
/// The meetup's photo and its headline, as a cover card: the picture on
/// top, the intent tag, the time and the place on the card surface under
/// it.
///
/// # THE TEXT CAME OUT FROM ON TOP OF THE PICTURE
///
/// The screen set lays the title over the photo with a scrim. That works
/// against the art it was drawn with; against these assets it does not.
/// They are bright, busy illustrations with faces and whiteboards in the
/// lower third, and no scrim that still lets the picture read is dark
/// enough to carry 17px white text over all of them. Deepening the scrim
/// until the text was safe turned the photo into a grey band, which is
/// the thing the hero existed to stop being.
///
/// So the text sits under the picture instead. It is always legible, in
/// both themes, whatever the image happens to contain — and the tag can
/// use the accent colours the rest of the app's tags use, rather than the
/// white-on-dark exception a photo overlay forced.
class _DetailHero extends StatelessWidget {
  const _DetailHero({required this.meetup});

  final Meetup meetup;

  @override
  Widget build(BuildContext context) {
    final locked = meetup.lockedForViewer;
    final width = MediaQuery.sizeOf(context).width;

    return FlatCard(
      radius: 22,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            // 124, not the screen set's 112. That number was drawn for a
            // band with the title ON it, where the photo is backing
            // texture. Here the label sits under the picture, so the
            // picture needs enough height to still lead.
            height: 124,
            width: double.infinity,
            child: Image.asset(
              meetup.intent.imageAsset,
              fit: BoxFit.cover,
              // Decoded at the band's real width, not the source's.
              cacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                  .round(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppTag(
                  meetup.intentLabel,
                  icon: meetup.intent.iconPath,
                  compact: true,
                ),
                const SizedBox(height: 10),
                Text(
                  locked ? 'Location hidden' : meetup.formattedWindow,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (!locked && meetup.locationLabel != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: AppIcon(
                          AppIcons.pin,
                          size: 14,
                          color: AppPalette.textTertiary,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          meetup.locationLabel!,
                          style: TextStyle(
                            color: AppPalette.textSecondary,
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CancelledBanner extends StatelessWidget {
  const _CancelledBanner({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final tone = AppPalette.cancelled;
    final text = reason.trim();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tone.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(AppIcons.calendarX, size: 16, color: tone),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Cancelled by the host',
                  style: TextStyle(
                    color: tone,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            text.isEmpty ? 'No reason was given.' : '\u201C$text\u201D',
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 13.5,
              fontStyle: text.isEmpty ? FontStyle.normal : FontStyle.italic,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// A full-width row button: icon in an accent disc, small-caps label with
/// a one-line detail, and a chevron. The chevron and the accent border are
/// what say "this goes somewhere"; the earlier centred icon-over-label tile
/// read as a badge rather than a control.
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.detail,
    required this.onTap,
  });

  final String icon;
  final String label;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppPalette.candyBlue;
    return Material(
      color: AppPalette.card,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        // A visible press state. The old bordered bars gave none, which is
        // half of why they did not read as buttons.
        splashColor: accent.withValues(alpha: 0.12),
        highlightColor: accent.withValues(alpha: 0.06),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent.withValues(alpha: 0.45)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: AppIcon(icon, size: 20, color: accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: AppPalette.textPrimary,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        style: TextStyle(
                          color: AppPalette.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                AppIcon(AppIcons.forward, size: 22, color: accent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChecklistItem extends StatelessWidget {
  const _ChecklistItem(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          AppIcon(
            AppIcons.checkCircle,
            size: 14,
            color: AppPalette.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _DoneRow extends StatelessWidget {
  const _DoneRow(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        AppIcon(AppIcons.checkCircle, size: 16, color: AppPalette.verified),
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            color: AppPalette.verified,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

/// The declined terminal state (ADR-024 §4) — same spirit as `_DoneRow`
/// (a static row, no longer offering check-in), danger-colored like every
/// other cancelled/withdrawn state already shown elsewhere in this app,
/// not a new visual language.

/// The withdraw-confirmation-with-optional-note dialog (ADR-020 §4), split
/// out as its own [StatefulWidget] for the same reason
/// `host_meetup_controls.dart`'s `_CancelReasonDialog` is — a
/// [TextEditingController] disposed manually right after `showDialog`
/// resolves races the dialog's exit transition and throws "used after
/// being disposed." Owning the controller in the State and disposing it in
/// `dispose()` ties disposal to the widget's actual removal instead.
/// Resolves to null on BACK/dismiss, or the (possibly empty) note text on
/// WITHDRAW.
/// Confirmation for cancelling a still-pending request. No note field:
/// the host has not acted, is not told, and there is nobody to explain
/// anything to.
class _CancelRequestDialog extends StatelessWidget {
  const _CancelRequestDialog();

  @override
  Widget build(BuildContext context) {
    return AppConfirmDialog(
      title: 'Cancel request',
      message:
          'Take back your request to join? The host has not answered yet, '
          'so nothing is sent to them. You can request again any time.',
      confirmLabel: 'Cancel request',
      cancelLabel: 'Keep it',
      danger: true,
      onConfirm: () => Navigator.pop(context, true),
      onCancel: () => Navigator.pop(context, false),
    );
  }
}

class _WithdrawNoteDialog extends StatefulWidget {
  const _WithdrawNoteDialog();

  @override
  State<_WithdrawNoteDialog> createState() => _WithdrawNoteDialogState();
}

class _WithdrawNoteDialogState extends State<_WithdrawNoteDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppConfirmDialog(
      title: 'Withdraw request',
      message: 'Withdraw your request to join this meetup?',
      confirmLabel: 'Withdraw request',
      cancelLabel: 'Back',
      danger: true,
      onConfirm: () => Navigator.pop(context, _controller.text.trim()),
      child: DialogTextArea(
        controller: _controller,
        hint: 'Note for the host (optional)',
      ),
    );
  }
}

/// The decline-with-reason dialog (ADR-024 §4) — mirrors
/// `host_meetup_controls.dart`'s `_CancelReasonDialog` exactly: a
/// [StatefulWidget] owning its own [TextEditingController], disposed
/// through the State's own `dispose()` rather than manually right after
/// `showDialog` resolves (which races the dialog's exit transition and
/// throws "A TextEditingController was used after being disposed" —
/// `_CancelReasonDialog`'s and `_WithdrawNoteDialog`'s own doc comments
/// document the same bug this pattern avoids). Reason is required — the
/// confirm button stays disabled until non-empty, same as
/// `_CancelReasonDialog`. Resolves to null on BACK/dismiss, or the trimmed
/// reason on DECLINE.
class _DeclineReasonDialog extends StatefulWidget {
  const _DeclineReasonDialog();

  @override
  State<_DeclineReasonDialog> createState() => _DeclineReasonDialogState();
}

class _DeclineReasonDialogState extends State<_DeclineReasonDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final trimmed = _controller.text.trim();
    return AppConfirmDialog(
      title: 'Decline',
      message:
          'Decline this meetup\'s safety checklist? The host will be '
          'notified with your reason.',
      confirmLabel: 'Decline',
      cancelLabel: 'Back',
      danger: true,
      // Null while the reason is empty, which leaves the confirm button
      // dimmed and inert rather than looking live and doing nothing.
      onConfirm: trimmed.isEmpty ? null : () => Navigator.pop(context, trimmed),
      child: DialogTextArea(
        controller: _controller,
        hint: 'Reason for declining (required)',
        onChanged: (_) => setState(() {}),
      ),
    );
  }
}
