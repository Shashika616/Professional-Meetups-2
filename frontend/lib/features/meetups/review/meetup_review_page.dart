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
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/core/widgets/skeleton_loader.dart';
import 'package:professional_connections_platform/features/meetups/review/experience_scale.dart';

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
            'SHARE YOUR THOUGHTS',
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 14,
              letterSpacing: 2,
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
              Icon(
                Icons.cloud_off_rounded,
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
                label: 'TRY AGAIN',
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
          FlatCard(
            radius: 14,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: TextField(
              controller: _notesController,
              maxLines: 3,
              minLines: 3,
              maxLength: 500,
              style: TextStyle(color: AppPalette.textPrimary, fontSize: 14),
              decoration: InputDecoration(
                border: InputBorder.none,
                counterText: '',
                hintText: 'Describe in detail (optional)',
                hintStyle: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 14,
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          PrimaryButton(
            label: _toRate.isEmpty ? 'SUBMIT' : 'NEXT',
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

  Widget _buildPeopleStep() {
    final traits = _data?.availableTraits ?? const <RatingTrait>[];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
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
                : 'Rate everyone to finish. Traits are optional.',
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 18),
          for (final participant in _toRate)
            _ParticipantCard(
              participant: participant,
              isHost: participant.userId == widget.hostUserId,
              traits: traits,
              score: _scores[participant.userId],
              selectedTraits: _traits[participant.userId] ?? const {},
              onScore: (score) =>
                  setState(() => _scores[participant.userId] = score),
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
            ),
          const SizedBox(height: 8),
          PrimaryButton(
            label: 'CONFIRM',
            isLoading: _submitting,
            onPressed: _allRated ? _submit : null,
          ),
          const SizedBox(height: 10),
          Center(
            child: TextButton(
              onPressed: _submitting ? null : () => _goToStep(0),
              child: Text(
                'BACK',
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  letterSpacing: 1.2,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
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
              Icon(Icons.event_busy_rounded, size: 16, color: tone),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'THIS MEETUP WAS CANCELLED BY THE HOST',
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

class _ParticipantCard extends StatelessWidget {
  const _ParticipantCard({
    required this.participant,
    required this.isHost,
    required this.traits,
    required this.score,
    required this.selectedTraits,
    required this.onScore,
    required this.onToggleTrait,
  });

  final RatableParticipant participant;
  final bool isHost;
  final List<RatingTrait> traits;
  final int? score;
  final Set<String> selectedTraits;
  final ValueChanged<int> onScore;
  final ValueChanged<String> onToggleTrait;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: FlatCard(
        radius: 14,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ProfessionalAvatar(
                  name: participant.fullName,
                  imageUrl: participant.profilePhotoUrl.isEmpty
                      ? null
                      : participant.profilePhotoUrl,
                  size: 40,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
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
                      if (isHost) ...[const SizedBox(height: 4), _HostTag()],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _StarRow(score: score, onScore: onScore),
            // The trait picker only appears once a score is given —
            // otherwise every card opens as a wall of chips and the thing
            // you are actually asked for is buried.
            AnimatedSize(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              // Nothing to show without a score, and nothing to show without
              // a vocabulary either: an empty trait list rendered the
              // "What were they like?" header over blank space, which reads
              // as a broken control rather than an absent one. It happens
              // for real whenever the server is older than this screen.
              child: (score == null || traits.isEmpty)
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: _TraitPicker(
                        traits: traits,
                        selected: selectedTraits,
                        onToggle: onToggleTrait,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// How many traits, across both tabs together, one rater may attach to one
/// person. Mirrors the server's own cap; the server still enforces it.
const int kMaxTraitsPerParticipant = 4;

/// The vocabulary under two tabs, Positive and Negative, with one shared
/// cap. Two tabs rather than one long wrap so a rater who only wants to say
/// something kind never has to read past a list of criticisms to do it,
/// and so the criticisms, when wanted, are a deliberate switch away rather
/// than mixed in. The tab remembers itself per card while the page lives.
class _TraitPicker extends StatefulWidget {
  const _TraitPicker({
    required this.traits,
    required this.selected,
    required this.onToggle,
  });

  final List<RatingTrait> traits;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  @override
  State<_TraitPicker> createState() => _TraitPickerState();
}

class _TraitPickerState extends State<_TraitPicker> {
  bool _showNegative = false;

  @override
  Widget build(BuildContext context) {
    // Partitioned once per build from the server's order, which is already
    // grouped; each tab keeps that order.
    final positive = <RatingTrait>[];
    final negative = <RatingTrait>[];
    for (final t in widget.traits) {
      (t.negative ? negative : positive).add(t);
    }
    // A vocabulary with no negative half (an older server) needs no tabs.
    final tabbed = negative.isNotEmpty && positive.isNotEmpty;
    final showing = _showNegative && tabbed ? negative : positive;
    final tone = _showNegative && tabbed
        ? AppPalette.danger
        : AppPalette.candyBlue;
    final atCap = widget.selected.length >= kMaxTraitsPerParticipant;

    int countIn(List<RatingTrait> list) =>
        list.where((t) => widget.selected.contains(t.key)).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'What were they like? (up to $kMaxTraitsPerParticipant)',
          style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
        ),
        if (tabbed) ...[
          const SizedBox(height: 10),
          _TraitTabs(
            showNegative: _showNegative,
            positiveCount: countIn(positive),
            negativeCount: countIn(negative),
            onChanged: (negative) => setState(() => _showNegative = negative),
          ),
          const SizedBox(height: 4),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final trait in showing)
              _TraitChip(
                trait: trait,
                tone: tone,
                selected: widget.selected.contains(trait.key),
                // At the cap, the unselected chips go quiet rather than
                // vanishing — the vocabulary stays legible.
                dimmed: atCap && !widget.selected.contains(trait.key),
                onTap: () => widget.onToggle(trait.key),
              ),
          ],
        ),
      ],
    );
  }
}

/// The picker's switch between its two halves: two equal, full-width
/// segments, read as a different KIND of thing from the chips beneath
/// them by size and treatment, not by colour fill. The active segment is
/// drawn at full size with its border and type in the tab's colour; the
/// inactive one sits slightly smaller and in grey. No solid fill: a filled
/// block in either brand colour swallowed the label, and the chips already
/// use tint for "selected", so the tabs must not. Each side carries a
/// count once anything there is chosen, so a rater on one tab can see
/// they have picked something on the other without switching back.
class _TraitTabs extends StatelessWidget {
  const _TraitTabs({
    required this.showNegative,
    required this.positiveCount,
    required this.negativeCount,
    required this.onChanged,
  });

  final bool showNegative;
  final int positiveCount;
  final int negativeCount;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _TraitSegment(
          key: const Key('traitTabPositive'),
          label: 'POSITIVE',
          icon: Icons.thumb_up_alt_rounded,
          count: positiveCount,
          active: !showNegative,
          tone: AppPalette.candyBlue,
          onTap: () => onChanged(false),
        ),
        const SizedBox(width: 10),
        _TraitSegment(
          key: const Key('traitTabNegative'),
          label: 'NEGATIVE',
          icon: Icons.thumb_down_alt_rounded,
          count: negativeCount,
          active: showNegative,
          tone: AppPalette.danger,
          onTap: () => onChanged(true),
        ),
      ],
    );
  }
}

class _TraitSegment extends StatelessWidget {
  const _TraitSegment({
    super.key,
    required this.label,
    required this.icon,
    required this.count,
    required this.active,
    required this.tone,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final int count;
  final bool active;
  final Color tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = active ? tone : AppPalette.textSecondary;
    return Expanded(
      child: Semantics(
        button: true,
        selected: active,
        label: count == 0 ? label : '$label, $count chosen',
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedScale(
            // The inactive tab steps back rather than the active one
            // stepping forward, so the active one is always at true size
            // and never clipped by the card.
            scale: active ? 1.0 : 0.94,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              height: 42,
              decoration: BoxDecoration(
                color: AppPalette.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: active ? tone : AppPalette.hairline,
                  width: active ? 1.8 : 1,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 15, color: foreground),
                  const SizedBox(width: 7),
                  Text(
                    label,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                  if (count > 0) ...[
                    const SizedBox(width: 7),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: tone.withValues(alpha: active ? 0.22 : 0.14),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '$count',
                        style: TextStyle(
                          color: tone,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HostTag extends StatelessWidget {
  const _HostTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
    );
  }
}

class _StarRow extends StatelessWidget {
  const _StarRow({required this.score, required this.onScore});

  final int? score;
  final ValueChanged<int> onScore;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 1; i <= 5; i++)
          GestureDetector(
            onTap: () => onScore(i),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: TweenAnimationBuilder<double>(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutBack,
                tween: Tween(end: (score ?? 0) >= i ? 1.0 : 0.0),
                builder: (context, t, _) => Transform.scale(
                  // Filled stars pop very slightly, so tapping a score
                  // registers as an action rather than a repaint.
                  scale: 1 + (t * 0.12),
                  child: Icon(
                    t > 0.5 ? Icons.star_rounded : Icons.star_outline_rounded,
                    size: 30,
                    color: Color.lerp(
                      AppPalette.textSecondary.withValues(alpha: 0.55),
                      AppPalette.gold,
                      t,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _TraitChip extends StatelessWidget {
  const _TraitChip({
    required this.trait,
    required this.tone,
    required this.selected,
    required this.dimmed,
    required this.onTap,
  });

  final RatingTrait trait;

  /// The selected colour: the tab's own, so a chosen criticism reads red
  /// and a chosen compliment reads blue wherever the chip is seen.
  final Color tone;
  final bool selected;
  final bool dimmed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: dimmed ? null : onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: dimmed ? 0.4 : 1,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? tone.withValues(alpha: 0.2) : AppPalette.card,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? tone : AppPalette.hairline,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(trait.emoji, style: const TextStyle(fontSize: 13)),
              const SizedBox(width: 6),
              Text(
                trait.label,
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
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
