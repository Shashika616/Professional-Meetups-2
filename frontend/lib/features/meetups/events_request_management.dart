part of 'events_page.dart';

/// A host's view of every request on one of their meetups — Accept/Reject
/// per pending request (frontend/meetup-scheduling-PLAN.md Step 8).
/// The host's request list for one meetup: accept, reject, cancel, close.
/// Public because the meetup page's VIEW REQUESTS tile opens it too; the
/// Events tab remains its home.
class RequestManagementPage extends ConsumerStatefulWidget {
  const RequestManagementPage({super.key, required this.meetup});

  final Meetup meetup;

  @override
  ConsumerState<RequestManagementPage> createState() =>
      RequestManagementPageState();
}

class RequestManagementPageState extends ConsumerState<RequestManagementPage> {
  late Meetup _meetup;
  List<MeetupRequestModel>? _requests;
  bool _loading = true;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _meetup = widget.meetup;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final service = ref.read(meetupServiceProvider);
      final requests = await service.listMeetupRequests(_meetup.id);
      // Also re-fetches the meetup itself, not just its requests — an
      // Accept here bumps acceptedCount server-side, which HostMeetupControls
      // needs to know about immediately: it hides CANCEL once a request has
      // been accepted (the backend rejects cancelling in that state), and a
      // stale local _meetup would otherwise keep showing an action that's
      // now guaranteed to 409.
      final meetup = await service.getMeetup(_meetup.id);
      if (!mounted) return;
      setState(() {
        _requests = requests;
        _meetup = meetup;
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

  Future<void> _respond(MeetupRequestModel request, bool accept) async {
    track(accept ? Cta.acceptRequest : Cta.declineRequest);
    try {
      await ref
          .read(meetupServiceProvider)
          .respondToRequest(request.id, accept: accept);
      if (!mounted) return;
      showSnack(
        context,
        accept ? 'Request accepted.' : 'Request rejected.',
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
      if (!mounted) return;
      showSnack(
        context,
        error is MeetupException
            ? error.message
            : 'Something went wrong. Please try again.',
        type: ToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: DefaultTabController(
        // Pending / Accepted / Rejected — the single combined list this
        // replaces showed every status inline in one scroll, making it
        // hard to see "who's still waiting" at a glance (ADR-020 §2).
        // Rejected also carries withdrawn requests, shown alongside
        // rejected ones since both represent "no longer pending, not
        // accepted" from the host's point of view.
        length: 3,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('Requests'),
            bottom: const TabBar(
              tabs: [
                Tab(text: 'Pending'),
                Tab(text: 'Accepted'),
                Tab(text: 'Rejected'),
              ],
            ),
          ),
          body: SafeArea(
            child: Column(
              children: [
                // Was previously missing entirely — this screen showed
                // requester cards with no context about the meetup itself,
                // and (the bug this addendum fixes) no way to close or
                // cancel it, even though tapping the calendar icon →
                // Hosting → a meetup is the normal way a host lands here
                // (ADR-016 addendum, 2026-08-20).
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: FlatCard(
                    radius: 18,
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            // The intent as a chip, the same one the
                            // browse card and the meetup page use. It was
                            // tracked uppercase type here, which is the
                            // style this app no longer uses anywhere else.
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: AppTag(
                                  _meetup.intentLabel,
                                  icon: _meetup.intent.iconPath,
                                  compact: true,
                                ),
                              ),
                            ),
                            MeetupStatusBadge(status: _meetup.status),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _meetup.formattedWindow,
                          style: TextStyle(
                            color: AppPalette.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        HostMeetupControls(
                          meetup: _meetup,
                          onChanged: (updated) =>
                              setState(() => _meetup = updated),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: _loading
                      ? const _RequestsSkeleton()
                      : _loadError != null
                      ? SkeletonThenFailure(
                          skeleton: const _RequestsSkeleton(),
                          failure: ListView(
                            children: [
                              LoadFailedState(
                                failure: LoadFailure.of(_loadError),
                                onRetry: _load,
                              ),
                            ],
                          ),
                        )
                      : _buildRequestTabs(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRequestTabs() {
    final requests = _requests!;
    final pending = requests
        .where((r) => r.status == MeetupRequestStatus.pending)
        .toList();
    final accepted = requests
        .where((r) => r.status == MeetupRequestStatus.accepted)
        .toList();
    final rejectedOrWithdrawn = requests
        .where(
          (r) =>
              r.status == MeetupRequestStatus.rejected ||
              r.status == MeetupRequestStatus.withdrawn,
        )
        .toList();

    return TabBarView(
      children: [
        // Title only, like the screen set's empty states. Each of these
        // second lines restated its own title at greater length.
        _buildRequestList(pending, (
          title: 'No one has asked yet',
          message: null,
        )),
        _buildRequestList(accepted, (
          title: 'No one confirmed yet',
          message: null,
        )),
        Column(
          children: [
            Expanded(
              child: _buildRequestList(rejectedOrWithdrawn, (
                title: 'Nothing declined',
                message: null,
              )),
            ),
            // A withdrawn requester becomes ratable once — this reuses the
            // same RatingPrompt widget the happened-based flow uses
            // elsewhere rather than a bespoke picker, so the score/
            // confirmation/immutability behavior is identical everywhere
            // (ADR-020 §4).
            //
            // Scoped to the people on THIS tab. The endpoint behind
            // RatingPrompt returns everyone the viewer may rate on the
            // meetup, which once the meetup completes is every attendee —
            // so unscoped it put the post-meetup rating flow under a
            // "No rejected or withdrawn requests." empty state. It still
            // self-hides when the scoped set is empty or already rated.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: RatingPrompt(
                meetupId: _meetup.id,
                onlyUserIds: rejectedOrWithdrawn
                    .where((r) => r.status == MeetupRequestStatus.withdrawn)
                    .map((r) => r.requesterId)
                    .toSet(),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRequestList(
    List<MeetupRequestModel> requests,
    ({String title, String? message}) empty,
  ) {
    if (requests.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          EmptyStateDeck(
            title: empty.title,
            message: empty.message,
            scenes: EmptyDeckScenes.requests,
          ),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      itemCount: requests.length,
      itemBuilder: (context, index) =>
          _RequestCard(request: requests[index], onRespond: _respond),
    );
  }
}

/// One requester's card in `RequestManagementPage`'s Pending/Accepted/
/// Rejected tabs (ADR-020 §2) — the same row shape the old single combined
/// list used, just now reused across three filtered lists instead of one.
class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.request, required this.onRespond});

  final MeetupRequestModel request;
  final void Function(MeetupRequestModel request, bool accept) onRespond;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: FlatCard(
        radius: 18,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The identity row opens the requester's public profile — the
            // host is deciding whether to let this person in, and a name
            // plus a level badge is not enough to decide on. Only the row
            // is tappable, so ACCEPT/DECLINE below stay unambiguous.
            Semantics(
              container: true,
              button: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => PublicProfilePage.open(
                  context,
                  userId: request.requesterId,
                  initialName: request.requesterFullName,
                ),
                child: Row(
                  children: [
                    ProfessionalAvatar(
                      name: request.requesterFullName,
                      imageUrl: request.requesterProfilePhotoUrl.isEmpty
                          ? null
                          : request.requesterProfilePhotoUrl,
                      size: 40,
                    ),
                    const SizedBox(width: 12),
                    // Name on its own line(s), never cut; badge and rating
                    // under it — same stack as the Home card's host header.
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            request.requesterFullName,
                            softWrap: true,
                            style: TextStyle(
                              color: AppPalette.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              height: 1.2,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              TrustLevelBadge(
                                trustLevel: request.requesterTrustLevel,
                              ),
                              StarRating(
                                average: request.requesterRatingAverage,
                                count: request.requesterRatingCount,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    AppIcon(
                      AppIcons.forward,
                      size: 18,
                      color: AppPalette.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
            // No verification chip row here. VerificationBadges takes
            // nothing but the trust level, so down a list it restated the
            // badge sitting 10px above it in three more chips per card.
            // The tap target on the identity row opens the requester's
            // profile, which is where the breakdown belongs.
            const SizedBox(height: 12),
            if (request.status == MeetupRequestStatus.pending)
              Row(
                children: [
                  Expanded(
                    child: PrimaryButton(
                      label: 'Accept',
                      height: 44,
                      onPressed: () => onRespond(request, true),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Red, by the product owner's call, in the app's tinted
                  // form rather than a full red fill: a danger label on a
                  // faint danger wash with a danger hairline, the same
                  // treatment Cancel meetup and Sign out carry. It reads
                  // as the negative of Accept without shouting over it.
                  Expanded(
                    child: SecondaryButton(
                      label: 'Reject',
                      height: 44,
                      color: AppPalette.danger,
                      fillColor: AppPalette.danger.withValues(alpha: 0.08),
                      borderColor: AppPalette.danger.withValues(alpha: 0.3),
                      onPressed: () => onRespond(request, false),
                    ),
                  ),
                ],
              )
            else
              // A chip, not tracked uppercase text. Every other settled
              // state in the app (the browse card's "You're in", the
              // meetup page's request status) is a chip; this was the one
              // place the same information was a line of type.
              //
              // Accepted is the only one that takes a tone: it is the one
              // outcome worth spotting while scanning a list. Rejected and
              // withdrawn stay neutral — they are over, not alarming.
              Align(
                alignment: Alignment.centerLeft,
                child: AppTag(
                  switch (request.status) {
                    MeetupRequestStatus.accepted => 'Accepted',
                    MeetupRequestStatus.rejected =>
                      request.autoRejected ? 'Full, auto-rejected' : 'Rejected',
                    MeetupRequestStatus.withdrawn => 'Withdrawn',
                    MeetupRequestStatus.pending => 'Pending',
                  },
                  icon: switch (request.status) {
                    MeetupRequestStatus.accepted => AppIcons.check,
                    MeetupRequestStatus.withdrawn => AppIcons.undo,
                    _ => AppIcons.info,
                  },
                  tone: request.status == MeetupRequestStatus.accepted
                      ? AppTone.success
                      : AppTone.neutral,
                  compact: true,
                ),
              ),
            // The requester's own note left when withdrawing (ADR-020 §4) —
            // only present on a withdrawn request, shown as context ahead
            // of the "Rate" action RatingPrompt surfaces below the list.
            if (request.status == MeetupRequestStatus.withdrawn &&
                (request.withdrawalNote?.isNotEmpty ?? false)) ...[
              const SizedBox(height: 8),
              Text(
                '"${request.withdrawalNote}"',
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The host's one action on a live meetup from the Events tab. Outlined
/// in the request colour rather than filled: it is a navigation into a
/// management screen, not a commitment, and a filled bar on every hosted
/// card would out-shout HOST YOUR OWN MEETUP below the list.
class _ViewRequestsButton extends StatelessWidget {
  const _ViewRequestsButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: AppIcon(AppIcons.people, size: 16, color: AppPalette.candyBlue),
      label: Text(
        'View requests',
        style: TextStyle(
          color: AppPalette.candyBlue,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.1,
        ),
      ),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(40),
        side: BorderSide(color: AppPalette.candyBlue.withValues(alpha: 0.45)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}

/// Shown while [MeetupService.listMeetupRequests] resolves — mirrors the
/// card shape `_RequestCard` renders once data actually arrives.
class _RequestsSkeleton extends StatelessWidget {
  const _RequestsSkeleton();

  @override
  Widget build(BuildContext context) =>
      SkeletonLoader(child: _content(context));

  /// The placeholder shapes themselves. [SkeletonLoader] above adds the
  /// delay-before-showing and the shimmer sweep, so every caller of this
  /// widget gets both without knowing about either.
  Widget _content(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      itemCount: 3,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: FlatCard(
          radius: 18,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const SkeletonBox(width: 40, height: 40, radius: 20),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: SkeletonBox(
                      width: double.infinity,
                      height: 14,
                      opacity: 0.08,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const SkeletonBox(width: 28, height: 16, radius: 8),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: SkeletonBox(
                      width: double.infinity,
                      height: 40,
                      radius: 10,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SkeletonBox(
                      width: double.infinity,
                      height: 40,
                      radius: 10,
                      opacity: 0.04,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
