import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/meetup_status_badge.dart';
import 'package:professional_connections_platform/core/widgets/secondary_button.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_box.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';
import 'package:professional_connections_platform/features/home/widgets/meetup_card.dart'
    show LockedCardHeader;
import 'package:professional_connections_platform/features/meetups/location_view_page.dart';
import 'package:professional_connections_platform/features/meetups/widgets/host_meetup_controls.dart';
import 'package:professional_connections_platform/features/meetups/participants_page.dart';
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
  String? _loadError;

  /// Set once the viewer confirms (SubmitMeetupFeedback, happened=true)
  /// that this meetup happened — one of three triggers for mounting
  /// [RatingPrompt] fresh so its own initState fetch runs exactly when
  /// eligibility just changed, rather than rendering it unconditionally
  /// from page load and leaving it stuck with a stale empty fetch (ADR-020
  /// §4 widens the other two triggers — see [_buildContent]).
  bool _feedbackHappened = false;

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
        _loadError = error is MeetupException
            ? error.message
            : 'Something went wrong. Please try again.';
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
  Future<void> _confirmWithdraw(String requestId) async {
    final note = await showDialog<String>(
      context: context,
      // Returns null on BACK/dismiss, or the (possibly empty) note text on
      // WITHDRAW — a plain bool wouldn't carry the note back out, so the
      // dialog itself resolves the confirm/note-capture into one value.
      builder: (context) => const _WithdrawNoteDialog(),
    );
    if (note == null) return;
    if (!mounted) return;
    try {
      await ref
          .read(meetupServiceProvider)
          .withdrawRequest(requestId, note: note.isEmpty ? null : note);
      if (!mounted) return;
      showSnack(context, 'Request withdrawn.', type: ToastType.success);
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
    final trustLevel =
        ref.watch(authSessionProvider).value?.profile?.trustLevel ?? 0;
    if (!meetup.lockedForViewer && meetup.intent.canJoin(trustLevel)) {
      return PrimaryButton(label: 'REQUEST TO JOIN', onPressed: _requestToJoin);
    }
    return PrimaryButton(
      label: 'REQUEST TO JOIN',
      onPressed: () {
        showSnack(
          context,
          '${meetup.intent.label} requires Level ${meetup.intent.requiredTrustLevelToJoin} trust. Verify your phone, personal email, and details to unlock it.',
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

  Future<void> _checkIn() async {
    try {
      final state = await ref
          .read(meetupServiceProvider)
          .checkIn(widget.meetupId);
      if (!mounted) return;
      setState(() => _safetyState = state);
      showSnack(context, 'Checked in.', type: ToastType.success);
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

  /// Decline the safety checklist/check-in stage with a required reason
  /// (ADR-024 §4) — the required-reason dialog mirrors
  /// `host_meetup_controls.dart`'s `_CancelReasonDialog` (same pattern
  /// ADR-020 already established, not a second one). The backend rejects
  /// this outright if the caller already checked in (mutual exclusion);
  /// that surfaces as a normal error toast like any other rejection here.
  Future<void> _confirmDecline() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => const _DeclineReasonDialog(),
    );
    if (reason == null) return;
    if (!mounted) return;
    try {
      final state = await ref
          .read(meetupServiceProvider)
          .declineCheckIn(widget.meetupId, reason);
      if (!mounted) return;
      setState(() => _safetyState = state);
      showSnack(context, 'Declined.', type: ToastType.success);
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

  Future<void> _submitFeedback({
    required bool happened,
    bool? feltSafe,
    bool? profileAccurate,
    bool? wouldMeetAgain,
  }) async {
    // Second, optional step (ADR-016) — a free-text note after the
    // happened/didn't-happen choice. Neither Save nor Skip (nor dismissing
    // the sheet) blocks reaching the actual submit call below; only Save
    // with real text carries a non-null value through.
    final notes = await _showFeedbackNoteSheet();
    if (!mounted) return;
    try {
      await ref
          .read(meetupServiceProvider)
          .submitMeetupFeedback(
            widget.meetupId,
            happened: happened,
            feltSafe: feltSafe,
            profileAccurate: profileAccurate,
            wouldMeetAgain: wouldMeetAgain,
            notes: notes,
          );
      if (!mounted) return;
      showSnack(context, 'Thanks for the feedback.', type: ToastType.success);
      if (happened) setState(() => _feedbackHappened = true);
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

  Future<String?> _showFeedbackNoteSheet() {
    final controller = TextEditingController();
    return showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _FeedbackNoteSheet(controller: controller),
    ).whenComplete(controller.dispose);
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

  // Every meetup has a real window now, "today" included (ADR-016) — no
  // more isToday-means-always-open special case. Opens 10 minutes before
  // windowStart, same grace period as before. windowStart can be null
  // (ADR-028 — GetMeetup redacts too as of round-5/6 hardening); in
  // practice this getter is only ever read once `_safetyState != null`
  // (build(), below), which itself only happens for a real participant —
  // ADR-028's round-6 participation exception means GetMeetup never
  // redacts a participant's own meetup, so a null windowStart shouldn't
  // reach here today. Handled defensively anyway (check-in unavailable,
  // not a crash) rather than relying on that chain staying true forever.
  bool get _checkInWindowOpen {
    final meetup = _meetup;
    if (meetup == null) return true;
    final windowStart = meetup.windowStart;
    if (windowStart == null) return false;
    return DateTime.now().isAfter(
      windowStart.subtract(const Duration(minutes: 10)),
    );
  }

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

  /// Whether the meetup has actually begun.
  ///
  /// "How did it go?" is gated on this. It used to be gated on nothing, so a
  /// meetup scheduled for next week offered IT HAPPENED / DIDN'T HAPPEN —
  /// and IT HAPPENED is what unlocks the rating block, so the host was shown
  /// a star picker for someone they had not met yet.
  ///
  /// windowStart, not windowEnd, so someone can report a no-show without
  /// sitting out the whole window. No grace period either, unlike
  /// [_checkInWindowOpen]: checking in slightly early is reasonable,
  /// reporting on a meetup slightly before it starts is not.
  bool get _meetupHasStarted {
    final windowStart = _meetup?.windowStart;
    if (windowStart == null) return false;
    return !DateTime.now().isBefore(windowStart);
  }

  @override
  Widget build(BuildContext context) {
    // Pushed as its own route from Home/Matches, not one of AppShell's
    // bottom-nav tabs — see EventsPage's matching comment for why this
    // needs its own AppBackground wrap rather than inheriting AppShell's.
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('MEETUP')),
        body: SafeArea(
          child: _loading
              ? const _MeetupDetailSkeleton()
              : _loadError != null
              ? Center(
                  child: Text(
                    _loadError!,
                    style: TextStyle(color: AppPalette.textSecondary),
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
        FlatCard(
          radius: 12,
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      meetup.intent.label,
                      style: TextStyle(
                        color: AppPalette.candyBlue,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.4,
                      ),
                    ),
                  ),
                  MeetupStatusBadge(status: meetup.status),
                ],
              ),
              const SizedBox(height: 8),
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
                Text(
                  meetup.formattedWindow,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  meetup.locationLabel!,
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Hosted by ${meetup.hostFullName!} • Level ${meetup.hostTrustLevel}',
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 12,
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
              ParticipantsStrip(meetupId: widget.meetupId),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SecondaryButton(
          label: 'VIEW PARTICIPANTS',
          height: 40,
          icon: Icons.groups_outlined,
          onPressed: () =>
              ParticipantsPage.open(context, meetupId: widget.meetupId),
        ),
        const SizedBox(height: 12),
        // ADR-029 (round-8 hardening) — LocationViewPage.open owns the gate
        // itself (toast + redirect), so this button is shown regardless of
        // hosting/request state and regardless of trust level. The trust
        // level is passed rather than re-derived there: this page already
        // has it, and a widget that navigates should not be reaching into
        // the session to decide whether it may.
        SecondaryButton(
          label: 'VIEW LOCATION',
          height: 40,
          onPressed: () => LocationViewPage.open(
            context,
            meetup,
            viewerTrustLevel:
                ref.watch(authSessionProvider).value?.profile?.trustLevel ?? 0,
          ),
        ),
        const SizedBox(height: 12),
        // Everything from here down is about GETTING to a meetup. A finished
        // one gets the review instead — see _isPastMeetup.
        if (_isPastMeetup) ...[
          MeetupReviewSection(
            meetupId: widget.meetupId,
            hostUserId: meetup.hostUserId,
            cancelled: meetup.status == MeetupStatus.cancelled,
          ),
        ] else ...[
          if (!meetup.isHostedByMe && meetup.myRequestStatus == null)
            _buildJoinAction(context, meetup)
          else if (!meetup.isHostedByMe && meetup.myRequestStatus != null) ...[
            _RequestStatusBanner(status: meetup.myRequestStatus!),
            if (_canWithdraw(meetup)) ...[
              const SizedBox(height: 10),
              SecondaryButton(
                label: 'WITHDRAW REQUEST',
                height: 40,
                color: AppPalette.danger,
                borderColor: AppPalette.danger,
                onPressed: () => _confirmWithdraw(meetup.myRequestId!),
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
              checkInWindowOpen: _checkInWindowOpen,
              meetupHasStarted: _meetupHasStarted,
              onAcknowledgeChecklist: _acknowledgeChecklist,
              onShareWithContacts: _shareWithContacts,
              onCheckIn: _checkIn,
              onDecline: _confirmDecline,
              onSubmitFeedback: _submitFeedback,
            ),
          ],
          // ADR-020 widens this beyond the original happened-based trigger:
          // a cancelled meetup makes a previously-accepted requester eligible
          // to rate the host, and a host is always worth checking since a
          // withdrawn requester becomes ratable independent of the meetup's
          // own status/window. RatingPrompt itself self-gates on whatever
          // ListRatableParticipants actually returns, rendering nothing if
          // there's still nothing to rate.
          if (_feedbackHappened ||
              meetup.status == MeetupStatus.cancelled ||
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
          radius: 12,
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

class _RequestStatusBanner extends StatelessWidget {
  const _RequestStatusBanner({required this.status});

  final MeetupRequestStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      MeetupRequestStatus.pending => ('REQUEST PENDING', AppPalette.candyBlue),
      MeetupRequestStatus.accepted => ('YOU\'RE IN', AppPalette.verified),
      MeetupRequestStatus.rejected => ('REQUEST DECLINED', AppPalette.danger),
      MeetupRequestStatus.withdrawn => ('WITHDRAWN', AppPalette.textSecondary),
    };
    return FlatCard(
      radius: 12,
      padding: const EdgeInsets.symmetric(vertical: 14),
      tint: color.withValues(alpha: 0.08),
      border: color.withValues(alpha: 0.3),
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.4,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

/// The Safety Gate sub-flow: checklist → optional live-location → check-in
/// → post-meetup feedback, in that order (Safety UX Flows.md's step order,
/// also enforced server-side — CheckIn rejects if the checklist hasn't
/// been acknowledged yet).
class _SafetyGateSection extends StatelessWidget {
  const _SafetyGateSection({
    required this.safetyState,
    required this.checkInWindowOpen,
    required this.meetupHasStarted,
    required this.onAcknowledgeChecklist,
    required this.onShareWithContacts,
    required this.onCheckIn,
    required this.onDecline,
    required this.onSubmitFeedback,
  });

  final SafetyState? safetyState;
  final bool checkInWindowOpen;

  /// Gates the "How did it go?" card — see `_meetupHasStarted`.
  final bool meetupHasStarted;
  final VoidCallback onAcknowledgeChecklist;
  final VoidCallback onShareWithContacts;
  final VoidCallback onCheckIn;
  final VoidCallback onDecline;
  final void Function({
    required bool happened,
    bool? feltSafe,
    bool? profileAccurate,
    bool? wouldMeetAgain,
  })
  onSubmitFeedback;

  @override
  Widget build(BuildContext context) {
    final acknowledged = safetyState?.checklistAcknowledged ?? false;
    final sharedCount = safetyState?.sharedWithContactIds.length ?? 0;
    final checkedIn = safetyState?.checkedIn ?? false;
    final declined = safetyState?.declined ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'SAFETY GATE',
          style: TextStyle(
            color: AppPalette.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.6,
          ),
        ),
        const SizedBox(height: 12),
        FlatCard(
          radius: 12,
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
                  label: 'I UNDERSTAND',
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
          radius: 12,
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
              SecondaryButton(
                label: sharedCount > 0 ? 'TELL SOMEONE ELSE' : 'TELL SOMEONE',
                height: 42,
                onPressed: onShareWithContacts,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FlatCard(
          radius: 12,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Check in',
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 8),
              if (checkedIn)
                const _DoneRow('Checked in')
              else if (declined)
                _DeclinedRow(reason: safetyState?.declineReason)
              else ...[
                if (!acknowledged)
                  Text(
                    'Acknowledge the checklist above first.',
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 12,
                    ),
                  )
                else if (!checkInWindowOpen)
                  Text(
                    'Check-in opens 10 minutes before the meetup.',
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 12,
                    ),
                  )
                else
                  PrimaryButton(
                    label: 'CHECK IN',
                    height: 44,
                    onPressed: onCheckIn,
                  ),
                const SizedBox(height: 8),
                SecondaryButton(
                  label: 'DECLINE',
                  height: 40,
                  color: AppPalette.danger,
                  borderColor: AppPalette.danger,
                  onPressed: onDecline,
                ),
              ],
            ],
          ),
        ),
        if (meetupHasStarted) ...[
          const SizedBox(height: 12),
          FlatCard(
            radius: 12,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'How did it go?',
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: PrimaryButton(
                        label: 'IT HAPPENED',
                        height: 42,
                        onPressed: () => onSubmitFeedback(
                          happened: true,
                          feltSafe: true,
                          profileAccurate: true,
                          wouldMeetAgain: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SecondaryButton(
                        label: 'DIDN\'T HAPPEN',
                        height: 42,
                        onPressed: () => onSubmitFeedback(happened: false),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
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
          Icon(
            Icons.check_circle_outline,
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
        Icon(Icons.check_circle, size: 16, color: AppPalette.verified),
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
class _DeclinedRow extends StatelessWidget {
  const _DeclinedRow({required this.reason});

  final String? reason;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.cancel, size: 16, color: AppPalette.danger),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            (reason == null || reason!.isEmpty)
                ? 'Declined'
                : 'Declined: $reason',
            style: TextStyle(
              color: AppPalette.danger,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }
}

/// The "add a note" step after the happened/didn't-happen choice (ADR-016)
/// — entirely optional, both Save and Skip (and dismissing the sheet
/// itself) proceed to the real feedback submission; only Save with
/// non-empty text carries a note through.
class _FeedbackNoteSheet extends StatelessWidget {
  const _FeedbackNoteSheet({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: FlatCard(
        radius: 12,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Add a note (optional)',
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 12),
            FlatCard(
              radius: 12,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: TextField(
                controller: controller,
                maxLines: 4,
                style: TextStyle(color: AppPalette.textPrimary, fontSize: 14),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: 'Anything worth remembering about this meetup?',
                  hintStyle: TextStyle(color: AppPalette.textSecondary),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: SecondaryButton(
                    label: 'SKIP',
                    height: 44,
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PrimaryButton(
                    label: 'SAVE',
                    height: 44,
                    onPressed: () {
                      final text = controller.text.trim();
                      Navigator.pop(context, text.isEmpty ? null : text);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The withdraw-confirmation-with-optional-note dialog (ADR-020 §4), split
/// out as its own [StatefulWidget] for the same reason
/// `host_meetup_controls.dart`'s `_CancelReasonDialog` is — a
/// [TextEditingController] disposed manually right after `showDialog`
/// resolves races the dialog's exit transition and throws "used after
/// being disposed." Owning the controller in the State and disposing it in
/// `dispose()` ties disposal to the widget's actual removal instead.
/// Resolves to null on BACK/dismiss, or the (possibly empty) note text on
/// WITHDRAW.
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
    return AlertDialog(
      backgroundColor: AppPalette.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        'WITHDRAW REQUEST',
        style: TextStyle(
          color: AppPalette.textPrimary,
          letterSpacing: 1.6,
          fontSize: 15,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Withdraw your request to join this meetup?',
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            maxLines: 3,
            style: TextStyle(color: AppPalette.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Note for the host (optional)',
              hintStyle: TextStyle(color: AppPalette.textSecondary),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'BACK',
            style: TextStyle(color: AppPalette.textSecondary),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(
            'WITHDRAW',
            style: TextStyle(
              color: AppPalette.danger,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
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
    return AlertDialog(
      backgroundColor: AppPalette.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        'DECLINE',
        style: TextStyle(
          color: AppPalette.danger,
          letterSpacing: 1.6,
          fontSize: 15,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Decline this meetup\'s safety checklist? The host will be '
            'notified with your reason.',
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            onChanged: (_) => setState(() {}),
            maxLines: 3,
            style: TextStyle(color: AppPalette.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Reason for declining (required)',
              hintStyle: TextStyle(color: AppPalette.textSecondary),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'BACK',
            style: TextStyle(color: AppPalette.textSecondary),
          ),
        ),
        TextButton(
          onPressed: trimmed.isEmpty
              ? null
              : () => Navigator.pop(context, trimmed),
          child: Text(
            'DECLINE',
            // Greyed while disabled. `onPressed: null` already blocks the
            // tap, but an explicit `style:` overrides TextButton's own
            // disabled colour, so the control looked fully active while
            // doing nothing — the user reads that as a broken button, not
            // as "fill the field in".
            style: TextStyle(
              color: trimmed.isEmpty
                  ? AppPalette.textSecondary.withValues(alpha: 0.45)
                  : AppPalette.danger,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}
