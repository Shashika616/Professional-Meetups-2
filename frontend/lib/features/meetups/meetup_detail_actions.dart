part of 'meetup_detail_page.dart';

/// Part of _MeetupDetailPageState: rows, sections and actions, kept apart so the state class
/// reads as the page.
extension _MeetupDetailActions on _MeetupDetailPageState {
  Future<void> _requestToJoin() async {
    try {
      await ref.read(meetupServiceProvider).requestToJoin(widget.meetupId);
      final flow = Analytics.instance.flow(AnalyticsFlow.joinMeetup);
      flow.stepCompleted(AnalyticsFlowStep.joinMeetupRequest);
      flow.complete();
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
        MaterialPageRoute(
          settings: const RouteSettings(
            name: ScreenNames.verificationChecklist,
          ),
          builder: (_) => const VerificationChecklistPage(),
        ),
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
    } finally {
      // Any way out but success (an error, a conflict, the trust gate):
      // the funnel stopped at the request. Does nothing after complete().
      Analytics.instance
          .flow(AnalyticsFlow.joinMeetup)
          .abandon(AnalyticsValue.flowAbandonedReasonError);
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
    track(Cta.withdrawRequest);
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
          track(Cta.joinMeetup);
          // Plan 29E: the join funnel. The detail step is done when the
          // user asks to join; the request step when the server takes it.
          // Accepted is the server's own event (request_accepted).
          final flow = Analytics.instance.flow(AnalyticsFlow.joinMeetup);
          flow.stepViewed(AnalyticsFlowStep.joinMeetupDetail);
          flow.stepCompleted(AnalyticsFlowStep.joinMeetupDetail);
          flow.stepViewed(AnalyticsFlowStep.joinMeetupRequest);
          // Who is hosting, before anything is sent.
          if (!await showJoinConfirmationSheet(context, meetup: meetup)) {
            flow.abandon(AnalyticsValue.flowAbandonedReasonClosed);
            return;
          }
          await _requestToJoin();
        },
      );
    }
    return PrimaryButton(
      label: 'I\'m interested',
      onPressed: () {
        track(Cta.joinMeetup);
        showSnack(
          context,
          meetup.intent.joinLockedMessage,
          type: ToastType.locked,
        );
        Navigator.of(context).push(
          MaterialPageRoute(
            settings: const RouteSettings(
              name: ScreenNames.verificationChecklist,
            ),
            builder: (_) => const VerificationChecklistPage(),
          ),
        );
      },
    );
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
}
