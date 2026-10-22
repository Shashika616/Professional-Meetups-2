import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/pressable.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/scroll_more_hint.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';
import 'package:professional_connections_platform/features/meetups/review/experience_scale.dart';
import 'package:professional_connections_platform/features/meetups/review/participant_review_sheet.dart';
import 'package:professional_connections_platform/features/meetups/review/review_inputs.dart';

/// The post-meetup review: how the meetup went, then how each person was.
///
/// # WHY IT IS TWO STEPS AND NOT ONE LONG FORM
///
/// The two questions are about different things — the meetup, then the
/// people — and asking them on one screen makes the overall score read like
/// a sixth participant. Splitting them also means the first thing anyone
/// sees is a single, large, unmissable question rather than a wall of rows,
/// which is the difference between a form and something someone finishes.
///
/// # WHY IT SUBMITS ONCE, AT THE END
///
/// Ratings are immutable server-side, so anything written before Confirm
/// could never be corrected. The whole review goes up as one call and either
/// lands or doesn't — see the backend's SubmitMeetupReview.
class MeetupReviewPage extends ConsumerStatefulWidget {
  const MeetupReviewPage({
    super.key,
    required this.meetupId,
    required this.hostUserId,
    this.cancellationReason,
  });

  final String meetupId;

  /// Used only to badge the host in the participant list — the read of who
  /// can be rated comes from the server.
  final String hostUserId;

  /// Set when the meetup was CANCELLED by its host and this is the
  /// participant's review of that: the page says so up front, quotes the
  /// host's reason, and the people step (the server offers only the host
  /// for a cancelled meetup) is framed as rating the host rather than
  /// "who did you meet". Null for an ordinary post-meetup review. An empty
  /// string means cancelled with no reason given.
  final String? cancellationReason;

  @override
  ConsumerState<MeetupReviewPage> createState() => _MeetupReviewPageState();
}

class _MeetupReviewPageState extends ConsumerState<MeetupReviewPage> {
  final _pageController = PageController();
  final _notesController = TextEditingController();

  RatableParticipants? _data;
  bool _loading = true;
  Object? _loadError;
  bool _submitting = false;

  /// Drives the people list and the "more below" chevron over it.
  final _peopleScroll = ScrollController();

  ExperienceLevel? _overall;
  final Map<String, int> _scores = {};
  final Map<String, Set<String>> _traits = {};

  int _step = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _notesController.dispose();
    _peopleScroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await ref
          .read(meetupServiceProvider)
          .listRatableParticipantsWithTraits(widget.meetupId);
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
        _loadError = error;
        _loading = false;
      });
    }
  }

  List<RatableParticipant> get _toRate =>
      (_data?.participants ?? const []).where((p) => !p.alreadyRated).toList();

  /// Every outstanding participant scored. The server enforces the same
  /// rule, so this is about not letting someone reach a Confirm that would
  /// only fail.
  bool get _allRated => _toRate.every((p) => _scores.containsKey(p.userId));

  void _goToStep(int step) {
    setState(() => _step = step);
    _pageController.animateToPage(
      step,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeInOutCubic,
    );
  }

  Future<void> _submit() async {
    final overall = _overall;
    if (overall == null || _submitting) return;
    setState(() => _submitting = true);

    final notes = _notesController.text.trim();
    try {
      await ref
          .read(meetupServiceProvider)
          .submitMeetupReview(
            widget.meetupId,
            overallScore: overall.score,
            notes: notes.isEmpty ? null : notes,
            participants: _toRate
                .map(
                  (p) => ReviewParticipantInput(
                    userId: p.userId,
                    score: _scores[p.userId]!,
                    traits: (_traits[p.userId] ?? const <String>{}).toList(),
                  ),
                )
                .toList(),
          );
      if (!mounted) return;
      // The meetup leaves the home list the moment this lands, so both
      // lists that render it have to be refetched.
      ref.invalidate(activeMeetupsProvider);
      ref.invalidate(myMeetupsProvider);
      Navigator.of(context).pop(true);
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
      setState(() => _submitting = false);
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
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text(
            'Share your thoughts',
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 14,
              letterSpacing: 0.6,
              fontWeight: FontWeight.w600,
            ),
          ),
          centerTitle: true,
          iconTheme: IconThemeData(color: AppPalette.textPrimary),
        ),
        body: SafeArea(top: false, child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: SkeletonLoader(child: _ReviewSkeleton()),
      );
    }
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(
                AppIcons.cloudOff,
                size: 40,
                color: AppPalette.textSecondary,
              ),
              const SizedBox(height: 12),
              Text(
                "Couldn't load this meetup.",
                style: TextStyle(color: AppPalette.textSecondary),
              ),
              const SizedBox(height: 16),
              PrimaryButton(
                label: 'Try again',
                height: 44,
                onPressed: () {
                  setState(() {
                    _loading = true;
                    _loadError = null;
                  });
                  _load();
                },
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        _StepIndicator(step: _step),
        Expanded(
          child: PageView(
            controller: _pageController,
            // Driven only by the buttons: a stray swipe past an unanswered
            // question would land on a Confirm that cannot be pressed.
            physics: const NeverScrollableScrollPhysics(),
            children: [_buildOverallStep(), _buildPeopleStep()],
          ),
        ),
      ],
    );
  }

  Widget _buildOverallStep() {
    final level = _overall;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        children: [
          const SizedBox(height: 8),
          if (widget.cancellationReason != null) ...[
            _CancelledNotice(reason: widget.cancellationReason!),
            const SizedBox(height: 22),
          ],
          Text(
            widget.cancellationReason != null
                ? 'How was this for you?'
                : 'How was your experience?',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 26,
              fontWeight: FontWeight.w700,
              height: 1.25,
            ),
          ),
          SizedBox(height: widget.cancellationReason != null ? 24 : 36),
          // The face morphs and its word cross-fades, so dragging the
          // slider reads as one thing changing its mind.
          // Full width: the scene is a landscape, and the room, table and
          // window are part of what carries the mood.
          LayoutBuilder(
            builder: (context, c) =>
                ExperienceFace(level: level, size: c.maxWidth),
          ),
          const SizedBox(height: 24),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(
              level?.label ?? 'Pick a rating',
              key: ValueKey(level),
              style: TextStyle(
                color: level?.color ?? AppPalette.textSecondary,
                fontSize: 24,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 28),
          ExperienceSlider(
            value: level,
            onChanged: (value) => setState(() => _overall = value),
          ),
          const SizedBox(height: 24),
          ReviewNotesField(controller: _notesController),
          const SizedBox(height: 20),
          PrimaryButton(
            label: _toRate.isEmpty ? 'Submit' : 'Next',
            // Disabled rather than hidden: the button's presence is what
            // tells someone the screen has a next step at all.
            onPressed: level == null
                ? null
                : (_toRate.isEmpty ? _submit : () => _goToStep(1)),
          ),
        ],
      ),
    );
  }

  /// Opens one person's rating sheet. The page stays the single owner of
  /// the answers: the sheet reports each change straight back here, so
  /// dismissing it by swiping down keeps whatever was already given.
  Future<void> _openParticipantSheet(
    RatableParticipant participant,
    List<RatingTrait> traits,
  ) {
    return showParticipantReviewSheet(
      context,
      participant: participant,
      isHost: participant.userId == widget.hostUserId,
      traits: traits,
      initialScore: _scores[participant.userId],
      initialTraits: _traits[participant.userId] ?? const {},
      onScore: (score) => setState(() => _scores[participant.userId] = score),
      onToggleTrait: (key) => setState(() {
        final selected = _traits.putIfAbsent(
          participant.userId,
          () => <String>{},
        );
        if (selected.contains(key)) {
          selected.remove(key);
        } else if (selected.length < kMaxTraitsPerParticipant) {
          selected.add(key);
        }
      }),
    );
  }

  /// The people step: a fixed header, a list that scrolls, and the actions
  /// pinned to the bottom.
  ///
  /// # WHY THE BUTTONS ARE NOT IN THE SCROLL VIEW
  ///
  /// They used to be the last children of one long scrolling column, which
  /// is fine for three people and wrong for twelve: CONFIRM sat below the
  /// twelfth row, so the way to finish was to scroll past everyone to find
  /// it, and nothing on the first screen said the step even had an end.
  /// Worse, the button that tells you whether you are DONE (it enables only
  /// once everyone is rated) was the one thing you could not see while
  /// rating.
  ///
  /// So the frame stays put and only the list moves inside it: the header
  /// says what is being asked, the actions are always within reach, and the
  /// list between them grows to whatever the guest list turned out to be.
  Widget _buildPeopleStep() {
    final traits = _data?.availableTraits ?? const <RatingTrait>[];
    final remaining = _toRate.where((p) => _scores[p.userId] == null).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.cancellationReason != null
                    ? 'Rate the host'
                    : 'Who did you meet?',
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.cancellationReason != null
                    ? 'Nobody met, so only the host is rated. Traits are optional.'
                    // With a long guest list, how many are LEFT is the more
                    // useful thing to say — it is the progress the pinned
                    // CONFIRM below is waiting on.
                    : remaining == 0
                    ? 'Everyone is rated. Traits are optional.'
                    : '$remaining of ${_toRate.length} still to rate. Traits are optional.',
                style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
              ),
            ],
          ),
        ),
        // One row per person, each opening their own sheet. The page's job
        // here is to show who is still to do; the rating itself happens in
        // a frame where the person and the words are together (see
        // showParticipantReviewSheet).
        Expanded(
          child: Stack(
            children: [
              ListView.builder(
                controller: _peopleScroll,
                // Clears the hint's fade strip, so the last row ends above
                // it rather than dissolving under the chevron.
                padding: const EdgeInsets.fromLTRB(
                  20,
                  0,
                  20,
                  ScrollMoreHint.stripHeight + 8,
                ),
                itemCount: _toRate.length,
                itemBuilder: (context, index) {
                  final participant = _toRate[index];
                  return _PersonRow(
                    participant: participant,
                    isHost: participant.userId == widget.hostUserId,
                    score: _scores[participant.userId],
                    traitCount:
                        (_traits[participant.userId] ?? const {}).length,
                    onTap: () => _openParticipantSheet(participant, traits),
                  );
                },
              ),
              // Says the list continues. With the actions pinned below,
              // the last visible row otherwise looks like the last row.
              ScrollMoreHint(controller: _peopleScroll),
            ],
          ),
        ),
        // Pinned. The hairline and the ground colour separate it from the
        // list scrolling underneath, so rows do not appear to slide out of
        // the buttons.
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: AppPalette.hairline)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PrimaryButton(
                  label: 'Confirm',
                  isLoading: _submitting,
                  onPressed: _allRated ? _submit : null,
                ),
                TextButton(
                  onPressed: _submitting ? null : () => _goToStep(0),
                  child: Text(
                    'Back',
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      letterSpacing: 1.2,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Two dots, so the flow says how long it is before someone starts it.
/// The cancellation, stated before anything is asked: what the state is,
/// and what the host said. The reason is shown as a quotation because it
/// is the host's words, not the app's.
class _CancelledNotice extends StatelessWidget {
  const _CancelledNotice({required this.reason});

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
                  'This meetup was cancelled by the host',
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

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.step});

  final int step;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < 2; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOut,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              height: 4,
              width: i == step ? 26 : 10,
              decoration: BoxDecoration(
                color: i == step ? AppPalette.candyBlue : AppPalette.hairline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ),
    );
  }
}

/// One person waiting to be rated, as a row that opens their sheet.
///
/// It carries its own state on its face — the stars given so far, or a
/// prompt if none — so the page answers "who is left?" at a glance without
/// opening anything. That is the whole reason the rating moved into a
/// sheet: this list can now be short enough to see at once.
class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.participant,
    required this.isHost,
    required this.score,
    required this.traitCount,
    required this.onTap,
  });

  final RatableParticipant participant;
  final bool isHost;
  final int? score;
  final int traitCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final rated = score != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Pressable(
        onTap: onTap,
        child: FlatCard(
          radius: 18,
          padding: const EdgeInsets.all(14),
          // A rated row takes a quiet green edge, so finished and
          // unfinished are told apart without reading either.
          border: rated
              ? AppPalette.verified.withValues(alpha: 0.45)
              : AppPalette.hairline,
          child: Row(
            children: [
              ProfessionalAvatar(
                name: participant.fullName,
                imageUrl: participant.profilePhotoUrl.isEmpty
                    ? null
                    : participant.profilePhotoUrl,
                size: 42,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            participant.fullName,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppPalette.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        if (isHost) ...[
                          const SizedBox(width: 8),
                          const HostTag(),
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    if (rated)
                      Row(
                        children: [
                          for (var i = 1; i <= 5; i++)
                            AppIcon(
                              i <= score! ? AppIcons.star : AppIcons.star,
                              size: 15,
                              color: i <= score!
                                  ? AppPalette.gold
                                  : AppPalette.textSecondary.withValues(
                                      alpha: 0.5,
                                    ),
                            ),
                          if (traitCount > 0) ...[
                            const SizedBox(width: 8),
                            Text(
                              traitCount == 1
                                  ? '1 trait'
                                  : '$traitCount traits',
                              style: TextStyle(
                                color: AppPalette.textSecondary,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ],
                      )
                    else
                      Text(
                        'Tap to rate',
                        style: TextStyle(
                          color: AppPalette.candyBlue,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              AppIcon(
                rated ? AppIcons.checkCircle : AppIcons.forward,
                size: rated ? 20 : 20,
                color: rated ? AppPalette.verified : AppPalette.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReviewSkeleton extends StatelessWidget {
  const _ReviewSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget box(double h, {double? w, double r = 12}) => Container(
      height: h,
      width: w,
      decoration: BoxDecoration(
        color: AppPalette.card,
        borderRadius: BorderRadius.circular(r),
      ),
    );
    return Column(
      children: [
        box(28, w: 240),
        const SizedBox(height: 36),
        box(110, w: 150, r: 55),
        const SizedBox(height: 28),
        box(24, w: 120),
        const SizedBox(height: 28),
        box(56),
        const SizedBox(height: 24),
        box(96),
      ],
    );
  }
}
