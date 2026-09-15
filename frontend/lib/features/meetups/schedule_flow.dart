import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/step_hero.dart';
import 'package:professional_connections_platform/core/widgets/time_field_24h.dart';
import 'package:professional_connections_platform/features/home/widgets/intent_tile.dart';
import 'package:professional_connections_platform/features/meetups/meetup_detail_page.dart';
import 'package:professional_connections_platform/features/meetups/meetup_window_input.dart';
import 'package:professional_connections_platform/features/meetups/widgets/map_location_step.dart';
import 'package:professional_connections_platform/features/verification/hosting_unlock_page.dart';

/// Test seam for the timing step's clock. The step refuses a start that is
/// already behind "now", which makes any widget test that types a fixed
/// time depend on the wall clock it happens to run under — 15:00 today is
/// in the past every afternoon. Tests pin this; production leaves it null
/// and reads the real clock. Same idiom as `debugStadiaApiKeyOverride`.
@visibleForTesting
DateTime Function()? debugScheduleFlowNowOverride;

/// Accumulates the host's choices across the Schedule flow's steps — a
/// plain mutable holder passed down to each step, not persisted anywhere
/// until the final Review step's `createMeetup` call
/// (frontend/meetup-scheduling-PLAN.md Step 7).
class _MeetupDraft {
  IntentType? intent;
  DateTime? windowStart;
  DateTime? windowEnd;
  double? locationLat;
  double? locationLng;
  String locationLabel = '';
  int capacity = 2;
}

enum _Step { intent, timing, location, capacity, review }

/// One consistent flow for every meetup — "today" is just a window whose
/// date happens to be today, no longer a separate no-time-entered path
/// (ADR-016 collapses the old "Schedule Today" / "Schedule for Later"
/// branching into a single timing step). Reached from the browse page's
/// "Schedule a Meetup" action.
class ScheduleFlowPage extends ConsumerStatefulWidget {
  const ScheduleFlowPage({super.key});

  @override
  ConsumerState<ScheduleFlowPage> createState() => _ScheduleFlowPageState();
}

class _ScheduleFlowPageState extends ConsumerState<ScheduleFlowPage> {
  final _draft = _MeetupDraft();
  _Step _step = _Step.intent;
  bool _submitting = false;

  List<_Step> get _sequence => [
    _Step.intent,
    _Step.timing,
    _Step.location,
    _Step.capacity,
    _Step.review,
  ];

  void _goNext() {
    final sequence = _sequence;
    final index = sequence.indexOf(_step);
    if (index < sequence.length - 1) {
      setState(() => _step = sequence[index + 1]);
    }
  }

  void _goBack() {
    final sequence = _sequence;
    final index = sequence.indexOf(_step);
    if (index > 0) {
      setState(() => _step = sequence[index - 1]);
    } else {
      Navigator.pop(context);
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      final meetup = await ref
          .read(meetupServiceProvider)
          .createMeetup(
            intent: _draft.intent!,
            windowStart: _draft.windowStart!,
            windowEnd: _draft.windowEnd!,
            locationLat: _draft.locationLat!,
            locationLng: _draft.locationLng!,
            locationLabel: _draft.locationLabel,
            capacity: _draft.capacity,
          );
      if (!mounted) return;
      showSnack(context, 'Meetup scheduled.', type: ToastType.success);
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => MeetupDetailPage(meetupId: meetup.id),
        ),
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
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Level 0 is the safe default while the profile hasn't resolved yet —
    // ADR-014 made Level 0 (Apple/Google/email, no LinkedIn) a real account
    // state, so this must never assume a higher level than confirmed.
    final trustLevel =
        ref.watch(authSessionProvider).value?.profile?.trustLevel ?? 0;

    // The OS back gesture used to pop the whole five-step wizard, throwing
    // away a part-filled draft — the in-app back button has always stepped
    // back one at a time. This makes the gesture do what the button does.
    //
    // canPop is true only on the first step, where leaving the flow really
    // is the right outcome; every later step is handled by _goBack().
    //
    // onPopInvokedWithResult, not onPopInvoked: the latter is deprecated in
    // this SDK (Flutter 3.47.0, see pop_scope.dart's @Deprecated) and
    // WillPopScope is gone entirely.
    return PopScope<void>(
      canPop: _sequence.indexOf(_step) == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _goBack();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: AppBackground(
          child: SafeArea(
            child: Column(
              children: [
                _Header(
                  onBack: _goBack,
                  step: _sequence.indexOf(_step) + 1,
                  total: _sequence.length,
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: switch (_step) {
                      _Step.intent => _IntentStep(
                        trustLevel: trustLevel,
                        selected: _draft.intent,
                        onPick: (intent) {
                          _draft.intent = intent;
                          _goNext();
                        },
                      ),
                      _Step.timing => _TimingStep(
                        initialStart: _draft.windowStart,
                        initialEnd: _draft.windowEnd,
                        onPick: (windowStart, windowEnd) {
                          _draft.windowStart = windowStart;
                          _draft.windowEnd = windowEnd;
                          _goNext();
                        },
                      ),
                      // MapLocationStep, not the commented-out _LocationStep
                      // stopgap below — frontend/meetup-scheduling-PLAN.md's
                      // 2026-08-18 testing addendum (Stadia Maps, provisional,
                      // see TESTING-NOTES.md). Provider-neutral name on
                      // purpose: swapping providers later means writing a new
                      // widget, not renaming this call site again.
                      _Step.location => MapLocationStep(
                        onSubmit: (lat, lng, label) {
                          _draft.locationLat = lat;
                          _draft.locationLng = lng;
                          _draft.locationLabel = label;
                          _goNext();
                        },
                      ),
                      _Step.capacity => _CapacityStep(
                        initial: _draft.capacity,
                        onSubmit: (capacity) {
                          _draft.capacity = capacity;
                          _goNext();
                        },
                      ),
                      _Step.review => _ReviewStep(
                        intent: _draft.intent!,
                        windowStart: _draft.windowStart!,
                        windowEnd: _draft.windowEnd!,
                        locationLabel: _draft.locationLabel,
                        capacity: _draft.capacity,
                        submitting: _submitting,
                        onConfirm: _submit,
                      ),
                    },
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

/// Title row plus a step counter and a thin progress track — a five-step
/// wizard with no indication of where you are in it is the single most
/// common thing missing from flows like this, and the fix is cheap.
class _Header extends StatelessWidget {
  const _Header({
    required this.onBack,
    required this.step,
    required this.total,
  });

  final VoidCallback onBack;
  final int step;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: onBack,
                icon: Icon(
                  Icons.arrow_back_ios_new_rounded,
                  size: 18,
                  color: AppPalette.textPrimary,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'SCHEDULE A MEETUP',
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.6,
                  ),
                ),
              ),
              Text(
                'STEP $step OF $total',
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: step / total),
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => LinearProgressIndicator(
                  value: value,
                  minHeight: 3,
                  backgroundColor: AppPalette.hairline,
                  color: AppPalette.brandGreen,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepTitle extends StatelessWidget {
  const _StepTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w800,
          color: AppPalette.textPrimary,
          height: 1.2,
        ),
      ),
    );
  }
}

class _IntentStep extends StatelessWidget {
  const _IntentStep({
    required this.trustLevel,
    required this.selected,
    required this.onPick,
  });

  final int trustLevel;
  final IntentType? selected;
  final void Function(IntentType intent) onPick;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StepTitle('What kind of meetup?'),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          // Image cards, not icon rows: roughly square so the scene reads
          // and there is room under it for the icon chip and name.
          childAspectRatio: 1.04,
          children: [
            for (final intent in IntentType.values)
              IntentTile(
                intent: intent,
                selected: intent == selected,
                locked: !intent.canHost(trustLevel),
                onTap: () {
                  // HOST-side gate (ADR-002 § 4) — this is the scheduling
                  // flow, so every intent here is being chosen to host.
                  //
                  // The destination is HostingUnlockPage, not the Level 2
                  // checklist. ADR-002 § 4 split the two gates but this call
                  // site kept the old redirect, so a Level 2 user — who can
                  // already join meetups — was sent to a page listing four
                  // things they finished long ago, with nothing on it that
                  // would actually unlock hosting. home_page.dart's
                  // onHostMeetup already routed correctly; this now matches.
                  // Deferred intents (ADR-004) are not a level to earn —
                  // sending someone to the unlock page for them promises
                  // something the page cannot deliver. Say so and stop.
                  if (intent.hostingDeferred) {
                    showSnack(
                      context,
                      '${intent.label[0]}${intent.label.substring(1).toLowerCase()} '
                      'meetups are not available yet.',
                      type: ToastType.locked,
                    );
                    return;
                  }
                  if (!intent.canHost(trustLevel)) {
                    showSnack(
                      context,
                      'Hosting a ${intent.label} meetup requires Level ${intent.requiredTrustLevelToHost} trust. Add your company details to unlock it.',
                      type: ToastType.locked,
                    );
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const HostingUnlockPage(),
                      ),
                    );
                    return;
                  }
                  onPick(intent);
                },
              ),
          ],
        ),
      ],
    );
  }
}

/// One consistent timing step for every meetup, "today" included (ADR-016)
/// — a date picker (defaulting to today) plus typed 24-hour FROM and TO
/// times. Every rule (strict `HH:MM`, start must still be ahead of the
/// clock, an end at or before the start means the next day) lives in
/// `meetup_window_input.dart` as pure functions; this widget only collects
/// input, shows the resolved outcome, and hands a concrete window up.
class _TimingStep extends StatefulWidget {
  const _TimingStep({
    required this.initialStart,
    required this.initialEnd,
    required this.onPick,
  });

  final DateTime? initialStart;
  final DateTime? initialEnd;
  final void Function(DateTime windowStart, DateTime windowEnd) onPick;

  @override
  State<_TimingStep> createState() => _TimingStepState();
}

class _TimingStepState extends State<_TimingStep> {
  late DateTime _date = widget.initialStart ?? _now();
  TimeOfDay? _from;
  TimeOfDay? _to;

  static DateTime _now() =>
      debugScheduleFlowNowOverride?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _from = widget.initialStart != null
        ? TimeOfDay.fromDateTime(widget.initialStart!)
        : null;
    _to = widget.initialEnd != null
        ? TimeOfDay.fromDateTime(widget.initialEnd!)
        : null;
  }

  ResolvedMeetupWindow? get _resolved {
    final from = _from;
    final to = _to;
    if (from == null || to == null) return null;
    return resolveMeetupWindow(date: _date, from: from, to: to, now: _now());
  }

  Future<void> _pickDate() async {
    final now = _now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date.isBefore(now) ? now : _date,
      firstDate: now,
      lastDate: now.add(const Duration(days: 90)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  String? _problemText(ResolvedMeetupWindow r) => switch (r.problem) {
    MeetupWindowProblem.none => null,
    MeetupWindowProblem.endEqualsStart =>
      'End time must be different from the start time.',
    MeetupWindowProblem.startInPast =>
      'That start time has already passed today. Pick a later time or '
          'another date.',
  };

  @override
  Widget build(BuildContext context) {
    final resolved = _resolved;
    final problem = resolved == null ? null : _problemText(resolved);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StepTitle('When should it happen?'),
        _IllustratedCard(
          asset: 'assets/images/schedule/date_card.jpg',
          onTap: _pickDate,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _FieldLabel('DATE'),
                    const SizedBox(height: 4),
                    Text(
                      formatPickedDate(_date, now: _now()),
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Tap to change',
                      style: TextStyle(
                        color: AppPalette.textSecondary,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: AppPalette.textSecondary,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // FROM and TO side by side in one card, an arrow between them —
        // the window is one thing, so it gets one surface.
        _IllustratedCard(
          asset: 'assets/images/schedule/time_card.jpg',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TimeField24h(
                      label: 'FROM',
                      initialValue: _from,
                      onChanged: (t) => setState(() => _from = t),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                    child: Icon(
                      Icons.arrow_forward_rounded,
                      size: 18,
                      color: AppPalette.textSecondary,
                    ),
                  ),
                  Expanded(
                    child: TimeField24h(
                      label: 'TO',
                      initialValue: _to,
                      onChanged: (t) => setState(() => _to = t),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Named outright: the fields accept only the 24-hour clock,
              // and a person used to "7:30" needs to be told so before
              // they type it, not by a rejected digit.
              Row(
                children: [
                  Icon(
                    Icons.schedule_rounded,
                    size: 13,
                    color: AppPalette.textSecondary,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      '24-hour format, e.g. 09:30 or 18:00',
                      style: TextStyle(
                        color: AppPalette.textSecondary,
                        fontSize: 11.5,
                        height: 1.2,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (problem != null) ...[
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 16,
                color: AppPalette.danger,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  problem,
                  style: TextStyle(color: AppPalette.danger, fontSize: 12),
                ),
              ),
            ],
          ),
        ] else if (resolved != null) ...[
          const SizedBox(height: 12),
          // The resolved window read back in one line, with its length —
          // the sanity check that catches a mistyped hour here rather than
          // on the review step. The next-day case gets a second, explicit
          // sentence: "(+1)" alone is timetable shorthand not everyone
          // reads.
          _WindowSummary(
            text: describeWindow(resolved),
            note: resolved.endsNextDay
                ? 'Ends the next day at ${formatTime24h(_to!)}.'
                : null,
          ),
        ],
        const SizedBox(height: 20),
        PrimaryButton(
          label: 'CONTINUE',
          onPressed: resolved != null && resolved.isValid
              ? () => widget.onPick(resolved.start, resolved.end)
              : null,
        ),
      ],
    );
  }
}

/// A timing-step card with an illustration panel down its right edge. The
/// panel keeps the artwork's own warm ground rather than tinting it to the
/// theme — it is meant to read as a picture on the card, the way the intent
/// cards carry their scenes. Decoded at panel size, not asset size.
class _IllustratedCard extends StatelessWidget {
  const _IllustratedCard({
    required this.asset,
    required this.child,
    this.onTap,
  });

  final String asset;
  final Widget child;
  final VoidCallback? onTap;

  static const double _panelWidth = 104;
  static const double _radius = 14;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final card = FlatCard(
      radius: _radius,
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_radius - 1),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                  child: child,
                ),
              ),
              SizedBox(
                width: _panelWidth,
                child: Image.asset(
                  asset,
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                  cacheWidth: (_panelWidth * dpr).round(),
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) =>
                      ColoredBox(color: AppPalette.surface),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (onTap == null) return card;
    return GestureDetector(onTap: onTap, child: card);
  }
}

/// The small-caps label the timing cards share with [TimeField24h].
class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: AppPalette.textSecondary,
        fontSize: 10.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.3,
      ),
    );
  }
}

/// The one-line readback under the timing fields — green edge like an
/// "active" meetup card, since what it describes is exactly the card that
/// is about to exist.
class _WindowSummary extends StatelessWidget {
  const _WindowSummary({required this.text, this.note});

  final String text;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppPalette.brandGreen.withValues(alpha: 0.08),
          border: Border(
            left: BorderSide(color: AppPalette.brandGreen, width: 3),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: [
              Icon(
                Icons.check_circle_outline_rounded,
                size: 16,
                color: AppPalette.brandGreen,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      text,
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (note != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        note!,
                        style: TextStyle(
                          color: AppPalette.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// FALLBACK STOPGAP — commented out, not deleted (frontend/meetup-
// scheduling-PLAN.md's 2026-08-18 testing addendum, Step 3). This manual
// lat/lng/label entry was the original placeholder for the location step
// before any map provider was wired up. It's kept here, fully intact, as
// the emergency fallback if the active map provider (currently Stadia
// Maps via MapLocationStep, see widgets/map_location_step.dart) ever needs
// to be temporarily disabled again — a bad/expired API key, a provider
// outage during a demo, etc. To bring it back: uncomment this block, and
// in the switch statement above swap `MapLocationStep(...)` back for
// `_LocationStep(...)`.
//
// /// **Blocked on Mapbox credentials (ADR-013 § 4)**: the real location step
// /// is a `mapbox_maps_flutter` map + Mapbox Search Box search bar, biased
// /// toward POI-category places, with the existing "Choose a public place..."
// /// safety copy from Safety UX Flows.md shown directly on screen. None of
// /// that is wired here — no Mapbox access token has been provided
// /// (`AppConfig.mapboxAccessToken`/`mapboxSearchAccessToken` are empty
// /// placeholders, see `core/config/app_config.dart`), and per
// /// frontend/meetup-scheduling-PLAN.md's own instruction, a token is never
// /// hardcoded and a missing one fails loudly rather than silently. This
// /// manual lat/lng/label entry is a clearly-labeled temporary stand-in so
// /// the rest of the flow (and CreateMeetup end-to-end) is still testable —
// /// replace this whole widget, not extend it, once real credentials land.
// class _LocationStep extends StatefulWidget {
//   const _LocationStep({required this.onSubmit});
//
//   final void Function(double lat, double lng, String label) onSubmit;
//
//   @override
//   State<_LocationStep> createState() => _LocationStepState();
// }
//
// class _LocationStepState extends State<_LocationStep> {
//   final _labelController = TextEditingController();
//   final _latController = TextEditingController();
//   final _lngController = TextEditingController();
//
//   @override
//   void initState() {
//     super.initState();
//     for (final c in [_labelController, _latController, _lngController]) {
//       c.addListener(_onFieldChanged);
//     }
//   }
//
//   void _onFieldChanged() => setState(() {});
//
//   @override
//   void dispose() {
//     for (final c in [_labelController, _latController, _lngController]) {
//       c.removeListener(_onFieldChanged);
//       c.dispose();
//     }
//     super.dispose();
//   }
//
//   bool get _canContinue =>
//       _labelController.text.trim().isNotEmpty &&
//       double.tryParse(_latController.text.trim()) != null &&
//       double.tryParse(_lngController.text.trim()) != null;
//
//   @override
//   Widget build(BuildContext context) {
//     return Column(
//       crossAxisAlignment: CrossAxisAlignment.stretch,
//       children: [
//         const _StepTitle('Where?'),
//         Container(
//           padding: const EdgeInsets.all(12),
//           decoration: BoxDecoration(
//             color: AppPalette.candyBlue.withValues(alpha: 0.08),
//             borderRadius: BorderRadius.circular(14),
//             border: Border.all(
//               color: AppPalette.candyBlue.withValues(alpha: 0.3),
//             ),
//           ),
//           child: const Text(
//             'Map search is pending a Mapbox access token — enter the '
//             'address and coordinates manually for now. This step will '
//             'be replaced with a real map + search once that\'s set up.',
//             style: TextStyle(color: AppPalette.candyBlue, fontSize: 11),
//           ),
//         ),
//         const SizedBox(height: 16),
//         // Choose a public place — never a stranger's home address
//         // (Safety UX Flows.md's pre-meetup safety copy, ADR-013 § 4).
//         const Text(
//           'Choose a public place — a cafe, restaurant, or well-known '
//           'venue, not a private residence.',
//           style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
//         ),
//         const SizedBox(height: 16),
//         GlassTextField(
//           controller: _labelController,
//           icon: Icons.place_outlined,
//           hint: 'Venue name / address',
//         ),
//         const SizedBox(height: 12),
//         GlassTextField(
//           controller: _latController,
//           icon: Icons.explore_outlined,
//           hint: 'Latitude (e.g. 6.9271)',
//           keyboardType: const TextInputType.numberWithOptions(
//             decimal: true,
//             signed: true,
//           ),
//         ),
//         const SizedBox(height: 12),
//         GlassTextField(
//           controller: _lngController,
//           icon: Icons.explore_outlined,
//           hint: 'Longitude (e.g. 79.8612)',
//           keyboardType: const TextInputType.numberWithOptions(
//             decimal: true,
//             signed: true,
//           ),
//         ),
//         const SizedBox(height: 20),
//         PrimaryButton(
//           label: 'CONTINUE',
//           onPressed: _canContinue
//               ? () => widget.onSubmit(
//                   double.parse(_latController.text.trim()),
//                   double.parse(_lngController.text.trim()),
//                   _labelController.text.trim(),
//                 )
//               : null,
//         ),
//       ],
//     );
//   }
// }

class _CapacityStep extends StatefulWidget {
  const _CapacityStep({required this.initial, required this.onSubmit});

  final int initial;
  final void Function(int capacity) onSubmit;

  @override
  State<_CapacityStep> createState() => _CapacityStepState();
}

class _CapacityStepState extends State<_CapacityStep> {
  late int _capacity = widget.initial;

  // Matches the backend's CHECK (capacity BETWEEN 1 AND 20) constraint —
  // keep these in sync (frontend/meetup-scheduling-PLAN.md Step 7).
  static const _min = 1;
  static const _max = 20;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StepTitle('How many people?'),
        const StepHero(asset: 'assets/images/schedule/capacity_card.jpg'),
        const SizedBox(height: 14),
        FlatCard(
          radius: 14,
          padding: const EdgeInsets.symmetric(vertical: 22),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _StepperButton(
                icon: Icons.remove_rounded,
                onTap: _capacity > _min
                    ? () => setState(() => _capacity--)
                    : null,
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$_capacity',
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                      color: AppPalette.textPrimary,
                      height: 1.0,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _capacity == 1 ? 'JUST YOU' : 'PEOPLE · INCLUDING YOU',
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
              _StepperButton(
                icon: Icons.add_rounded,
                onTap: _capacity < _max
                    ? () => setState(() => _capacity++)
                    : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        PrimaryButton(
          label: 'CONTINUE',
          onPressed: () => widget.onSubmit(_capacity),
        ),
      ],
    );
  }
}

class _StepperButton extends StatelessWidget {
  const _StepperButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: enabled
              ? AppPalette.tintedSurface(
                  AppPalette.candyBlue.withValues(alpha: 0.15),
                )
              : AppPalette.tintedSurface(
                  AppPalette.textPrimary.withValues(alpha: 0.05),
                ),
        ),
        child: Icon(
          icon,
          color: enabled ? AppPalette.candyBlue : AppPalette.textSecondary,
        ),
      ),
    );
  }
}

class _ReviewStep extends StatelessWidget {
  const _ReviewStep({
    required this.intent,
    required this.windowStart,
    required this.windowEnd,
    required this.locationLabel,
    required this.capacity,
    required this.submitting,
    required this.onConfirm,
  });

  final IntentType intent;
  final DateTime windowStart;
  final DateTime windowEnd;
  final String locationLabel;
  final int capacity;
  final bool submitting;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final crossesMidnight =
        windowEnd.year != windowStart.year ||
        windowEnd.month != windowStart.month ||
        windowEnd.day != windowStart.day;
    final placeLabel = locationLabel.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StepTitle('Review & confirm'),
        const StepHero(asset: 'assets/images/schedule/review_card.jpg'),
        const SizedBox(height: 14),
        FlatCard(
          radius: 14,
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ReviewRow(
                icon: intent.icon,
                label: 'INTENT',
                value: intent.label,
                detail: intent.tagline,
              ),
              const _ReviewDivider(),
              _ReviewRow(
                icon: Icons.schedule_rounded,
                label: 'WHEN',
                // formatMeetupWindow renders a midnight-crossing window as
                // e.g. "10:00 PM–1:00 AM" with no day marker — fine on a
                // card, but this is the last look before it is created, so
                // the next-day case gets its own line.
                value: formatMeetupWindow(windowStart, windowEnd),
                detail: crossesMidnight
                    ? 'Ends the next day, '
                          '${formatTime24h(TimeOfDay.fromDateTime(windowEnd))}'
                    : null,
              ),
              const _ReviewDivider(),
              _ReviewRow(
                icon: placeLabel.isEmpty
                    ? Icons.my_location_rounded
                    : Icons.place_outlined,
                label: 'LOCATION',
                // An empty label is the "use my current location" path
                // (ADR-029): coordinates are set, the address is resolved
                // server-side on creation. Say that rather than render a
                // blank row that looks like a bug.
                value: placeLabel.isEmpty
                    ? 'Your current location'
                    : placeLabel,
                detail: placeLabel.isEmpty
                    ? 'Address is filled in automatically when you schedule'
                    : null,
              ),
              const _ReviewDivider(),
              _ReviewRow(
                icon: Icons.people_outline,
                label: 'CAPACITY',
                value: capacity == 1 ? '1 person' : '$capacity people',
                detail: 'Including you',
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        PrimaryButton(
          label: 'CONFIRM & SCHEDULE',
          isLoading: submitting,
          onPressed: onConfirm,
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// One line of the review card: a small-caps label, the value under it in
/// the reading colour, and an optional secondary line. Stacked rather than
/// label-left/value-right so long values (an address, a window that ends
/// tomorrow) wrap as a paragraph instead of ragged-right against the label.
class _ReviewRow extends StatelessWidget {
  const _ReviewRow({
    required this.icon,
    required this.label,
    required this.value,
    this.detail,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppPalette.candyBlue.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: AppPalette.candyBlue),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.3,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                if (detail != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail!,
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 12,
                      height: 1.3,
                    ),
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

class _ReviewDivider extends StatelessWidget {
  const _ReviewDivider();

  @override
  Widget build(BuildContext context) {
    return Container(height: 1, color: AppPalette.hairline);
  }
}
