import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:professional_connections_platform/core/analytics/analytics.dart';
import 'package:professional_connections_platform/core/analytics/friction.dart';
import 'package:professional_connections_platform/core/analytics/flow_tracker.dart';
import 'package:professional_connections_platform/core/analytics/event_names.g.dart';
import 'package:professional_connections_platform/core/analytics/screen_names.dart';
import 'package:professional_connections_platform/core/models/credits.dart';
import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/providers/app_providers.dart';
import 'package:professional_connections_platform/core/services/credit_service.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/utils/uuid.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/app_back_button.dart';
import 'package:professional_connections_platform/core/widgets/app_background.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/flat_card.dart';
import 'package:professional_connections_platform/core/widgets/pressable.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';
import 'package:professional_connections_platform/core/widgets/step_hero.dart';
import 'package:professional_connections_platform/core/widgets/time_field_24h.dart';
import 'package:professional_connections_platform/features/credits/buy_credits_page.dart';
import 'package:professional_connections_platform/features/credits/credits_format.dart';
import 'package:professional_connections_platform/features/home/widgets/intent_tile.dart';
import 'package:professional_connections_platform/core/maps/map_canvas.dart';
import 'package:professional_connections_platform/features/home/viewer_location_provider.dart';
import 'package:professional_connections_platform/features/meetups/meetup_detail_page.dart';
import 'package:professional_connections_platform/features/meetups/meetup_window_input.dart';
import 'package:professional_connections_platform/features/meetups/widgets/map_location_step.dart';
import 'package:professional_connections_platform/features/meetups/widgets/schedule_conflict_sheet.dart';
import 'package:professional_connections_platform/features/verification/hosting_unlock_page.dart';

part 'schedule_flow_intent.dart';
part 'schedule_flow_timing.dart';
part 'schedule_flow_review.dart';

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

  /// How big and how far ahead this host may schedule, from the server's
  /// entitlements (plan 29C). The free limits until it answers, and if it
  /// cannot.
  CreationLimits _limits = CreationLimits.fallback;

  /// The review step's price, from the server. Null while it is asked.
  CreditQuote? _quote;
  Object? _quoteError;
  bool _quoting = false;

  /// A line above the cost when it needs saying again: the price changed,
  /// or the server wants this submission confirmed afresh.
  String? _costNotice;

  /// The server says creating is blocked until owed credits are paid.
  bool _debt = false;

  /// This submission's Idempotency-Key. Made on the first CONFIRM, kept
  /// for every retry of it (a timeout, a dropped connection) so the
  /// server creates one meetup and charges once, and dropped when the
  /// submission changes: a new price, or leaving the review step.
  String? _idempotencyKey;

  /// Plan 29E: the schedule-a-meetup funnel, one step per screen of the
  /// flow (the step names are the registry's, which match [_Step]).
  final FlowTracker _flow = Analytics.instance.flow(
    AnalyticsFlow.scheduleMeetup,
  );

  @override
  void initState() {
    super.initState();
    _flow.start();
    _flow.stepViewed(_step.name);
    _loadLimits();
  }

  @override
  void dispose() {
    // Left without scheduling (back, or the system gesture on step one).
    // Does nothing once the flow completed.
    _flow.abandon(AnalyticsValue.flowAbandonedReasonBack);
    super.dispose();
  }

  Future<void> _loadLimits() async {
    try {
      final e = await ref.read(creditServiceProvider).entitlements();
      if (mounted) setState(() => _limits = e.limits);
    } catch (_) {
      // The free limits stand; the server enforces the real ones anyway.
    }
  }

  /// Prices the draft. Called on reaching the review step and again after
  /// buying credits or being told the price changed.
  Future<void> _requestQuote() async {
    setState(() {
      _quoting = true;
      _quoteError = null;
    });
    try {
      final quote = await ref
          .read(creditServiceProvider)
          .quote(capacity: _draft.capacity, windowStart: _draft.windowStart!);
      if (!mounted) return;
      final old = _quote;
      setState(() {
        _quote = quote;
        if (old == null ||
            old.cost != quote.cost ||
            old.priceVersion != quote.priceVersion) {
          // A different price is a different submission.
          _idempotencyKey = null;
        }
      });
    } on CreditSessionExpiredException {
      if (mounted) ref.read(authSessionProvider.notifier).forceSignOut();
    } catch (e) {
      if (mounted) setState(() => _quoteError = e);
    } finally {
      if (mounted) setState(() => _quoting = false);
    }
  }

  Future<void> _buyCredits() async {
    track(Cta.buyCredits);
    final bought = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: ScreenNames.buyCredits),
        builder: (context) => const BuyCreditsPage(),
      ),
    );
    if (!mounted) return;
    if (bought == true) {
      _debt = false;
      _costNotice = null;
    }
    await _requestQuote();
  }

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
      _flow.stepCompleted(_step.name);
      setState(() => _step = sequence[index + 1]);
      _flow.stepViewed(_step.name);
      if (_step == _Step.review) {
        _costNotice = null;
        unawaited(_requestQuote());
      }
    }
  }

  void _goBack() {
    final sequence = _sequence;
    final index = sequence.indexOf(_step);
    if (index > 0) {
      setState(() {
        if (_step == _Step.review) {
          // Anything may change before the next review: a new submission.
          _quote = null;
          _idempotencyKey = null;
        }
        _step = sequence[index - 1];
      });
      _flow.stepViewed(_step.name);
    } else {
      Navigator.pop(context);
    }
  }

  /// The time step's CONTINUE. Asks the server whether the window is free
  /// before moving on (ADR-005): being told here beats being told after
  /// the place and headcount are picked. A conflict shows the same sheet
  /// the create call would, and the step stays put so another time can be
  /// chosen. If the check itself fails (offline, a server error) the flow
  /// continues: the create call enforces the rule regardless, and a
  /// network blip must not stop someone scheduling.
  Future<void> _pickWindow(DateTime windowStart, DateTime windowEnd) async {
    Meetup? conflict;
    try {
      conflict = await ref
          .read(meetupServiceProvider)
          .findScheduleConflict(windowStart: windowStart, windowEnd: windowEnd);
    } on MeetupSessionExpiredException {
      if (mounted) ref.read(authSessionProvider.notifier).forceSignOut();
      return;
    } catch (_) {
      conflict = null;
    }
    if (!mounted) return;
    if (conflict != null) {
      // Not awaited: CONTINUE's spinner is tied to this method, and it
      // should stop the moment the sheet is up, not when it is closed.
      unawaited(
        showScheduleConflictSheet(
          context,
          error: MeetupScheduleConflictException(
            'You already have a meetup at that time.',
            conflict: conflict,
          ),
        ),
      );
      return;
    }
    _draft.windowStart = windowStart;
    _draft.windowEnd = windowEnd;
    _goNext();
  }

  Future<void> _submit() async {
    final quote = _quote;
    if (_submitting || quote == null) return;
    final key = _idempotencyKey ??= uuidV4();
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
            charge: CreationCharge(
              expectedCost: quote.cost,
              priceVersion: quote.priceVersion,
              idempotencyKey: key,
            ),
          );
      _flow.stepCompleted(_Step.review.name);
      _flow.complete();
      if (!mounted) return;
      ref.invalidate(walletProvider);
      showSnack(context, 'Meetup scheduled.', type: ToastType.success);
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          settings: const RouteSettings(name: ScreenNames.meetupDetail),
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
    } on MeetupScheduleConflictException catch (error) {
      // Already committed elsewhere in this window: the sheet names the
      // meetup in the way and how to free the time. The draft is kept,
      // so a different time can be picked with the back button.
      if (mounted) await showScheduleConflictSheet(context, error: error);
    } on MeetupPriceChangedException catch (error) {
      // The price moved under the review step. Show the new one and ask
      // again; nothing was charged.
      if (!mounted) return;
      setState(() {
        _costNotice =
            'The price is now ${formatCredits(error.cost)}. Check it and '
            'confirm again.';
        _idempotencyKey = null;
      });
      await _requestQuote();
    } on MeetupIdempotencyKeyReusedException {
      if (!mounted) return;
      setState(() {
        _costNotice = 'Please confirm again.';
        _idempotencyKey = null;
      });
      await _requestQuote();
    } on MeetupInsufficientCreditsException catch (error) {
      // Credits changed since the quote. The button becomes BUY CREDITS.
      if (!mounted) return;
      setState(
        () => _costNotice =
            'You need ${formatCredits(error.shortfall)} more to schedule this.',
      );
      await _requestQuote();
    } on MeetupCreditsDebtException catch (error) {
      if (!mounted) return;
      setState(() {
        _debt = true;
        _costNotice = error.message;
      });
    } on MeetupUpdateRequiredException catch (error) {
      // The server's own sentence ("Update TieHere to host a meetup.").
      if (mounted) showSnack(context, error.message, type: ToastType.error);
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
    final trustLevel = ref.watch(
      authSessionProvider.select((s) => s.value?.profile?.trustLevel ?? 0),
    );

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
        // On the location step the keyboard COVERS the lower sheet instead
        // of shrinking the layout. Shrinking resized the native map view on
        // every frame of the keyboard's slide — the stutter — and pushed up
        // a sheet nobody needs while typing in the search field at the top.
        // The suggestions list sizes itself to the room above the keyboard.
        // Every other step keeps the default: its fields must stay visible.
        resizeToAvoidBottomInset: _step != _Step.location,
        body: AppBackground(
          child: SafeArea(
            child: Column(
              children: [
                _Header(
                  onBack: _goBack,
                  step: _sequence.indexOf(_step) + 1,
                  total: _sequence.length,
                ),
                // Plan 29E: a step left a minute without input is friction.
                Expanded(
                  child: DwellTracker(
                    stepKey: _step,
                    child: _stepBody(trustLevel),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// One step's body, wrapped the way that step needs.
  ///
  /// # WHY THE LOCATION STEP IS NOT SCROLLED
  ///
  /// Every other step is a column of controls that can outgrow the screen,
  /// so each gets a scroll view and the flow's 24pt gutter. The location
  /// step is a map: it has to fill the space it is given, edge to edge,
  /// with its own panel on the bottom edge — a scroll view would hand it
  /// unbounded height (a Stack cannot lay out in that) and the gutter
  /// would leave the map floating in a frame.
  ///
  /// So the wrapper is chosen per step rather than applied to all of them.
  /// The switch below still covers every case, so adding a step is still a
  /// compile error until it is handled.
  Widget _stepBody(int trustLevel) {
    final body = switch (_step) {
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
        maxAdvanceDays: _limits.maxAdvanceDays,
        onPick: _pickWindow,
      ),
      // MapLocationStep, not the commented-out _LocationStep
      // stopgap below — frontend/meetup-scheduling-PLAN.md's
      // 2026-08-18 testing addendum (Stadia Maps, provisional,
      // see TESTING-NOTES.md). Provider-neutral name on
      // purpose: swapping providers later means writing a new
      // widget, not renaming this call site again.
      _Step.location => MapLocationStep(
        startAt: switch (ref.read(knownViewerLocationProvider)) {
          final known? => MapPoint(known.lat, known.lng),
          null => null,
        },
        onSubmit: (lat, lng, label) {
          _draft.locationLat = lat;
          _draft.locationLng = lng;
          _draft.locationLabel = label;
          _goNext();
        },
      ),
      _Step.capacity => _CapacityStep(
        initial: _draft.capacity.clamp(1, _limits.maxCapacity),
        max: _limits.maxCapacity,
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
        quote: _quote,
        quoting: _quoting,
        quoteFailed: _quoteError != null,
        notice: _costNotice,
        blockedByDebt: _debt,
        onRetryQuote: _requestQuote,
        onBuyCredits: _buyCredits,
        onConfirm: _submit,
      ),
    };

    // The map fills whatever it is handed; everything else scrolls inside
    // the flow's own gutter.
    if (_step == _Step.location) return body;
    // The timing step is handed AT LEAST the height of the viewport, so
    // it can push its CONTINUE to the bottom edge with a Spacer instead
    // of leaving the button stranded halfway up a blank page — and it
    // still scrolls when the content is taller than the screen, which a
    // SliverFillRemaining would not have done (it sizes its child past
    // the viewport without making the overflow reachable).
    //
    // Only that step: IntrinsicHeight questions its child, and the
    // intent step's shrink-wrapped GridView is a viewport, which cannot
    // answer a question about its own intrinsic height.
    if (_step == _Step.timing) {
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(child: body),
          ),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: body,
    );
  }
}
