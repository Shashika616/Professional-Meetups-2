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
import 'package:professional_connections_platform/features/home/widgets/intent_tile.dart';
import 'package:professional_connections_platform/features/meetups/meetup_detail_page.dart';
import 'package:professional_connections_platform/features/meetups/widgets/map_location_step.dart';
import 'package:professional_connections_platform/features/verification/hosting_unlock_page.dart';

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
          imageOpacity: 0.35,
          child: SafeArea(
            child: Column(
              children: [
                _Header(onBack: _goBack),
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

class _Header extends StatelessWidget {
  const _Header({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 20, 8),
      child: Row(
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
          Text(
            'SCHEDULE A MEETUP',
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.6,
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

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: FlatCard(
        radius: 12,
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Icon(icon, size: 28, color: AppPalette.candyBlue),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: AppPalette.textSecondary),
          ],
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
          childAspectRatio: 2.1,
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

/// Shared FROM/TO time picker for [_TimingStep] — forces 24-hour format
/// and themes the dialog to match this app's dark glassmorphism design
/// instead of Flutter's plain default.
///
/// Forcing `alwaysUse24HourFormat` fixes a real bug, not just a look: on a
/// device/locale that renders `showTimePicker` in 12-hour mode, neither
/// the dial nor the keyboard-entry fields ever show a literal "00" —
/// midnight is only reachable by picking "12" and then toggling to AM,
/// which is exactly where users were getting stuck ("can't schedule at
/// 00:00"). A 24-hour dial/keyboard has hours 00–23 directly, with no
/// AM/PM toggle to get wrong.
Future<TimeOfDay?> _pickMeetupTime(
  BuildContext context,
  TimeOfDay initialTime,
) {
  return showTimePicker(
    context: context,
    initialTime: initialTime,
    builder: (context, child) {
      return MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: Theme(
          data: Theme.of(context).copyWith(
            timePickerTheme: TimePickerThemeData(
              backgroundColor: AppPalette.card,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: AppPalette.hairline),
              ),
              helpTextStyle: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
              ),
              dialBackgroundColor: AppPalette.surface,
              dialHandColor: AppPalette.candyBlue,
              dialTextColor: WidgetStateColor.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? AppPalette.onyx
                    : AppPalette.textPrimary,
              ),
              hourMinuteColor: WidgetStateColor.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? AppPalette.candyBlue.withValues(alpha: 0.16)
                    : AppPalette.surface,
              ),
              hourMinuteTextColor: WidgetStateColor.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? AppPalette.candyBlue
                    : AppPalette.textPrimary,
              ),
              hourMinuteShape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: AppPalette.hairline),
              ),
              entryModeIconColor: AppPalette.candyBlue,
              cancelButtonStyle: TextButton.styleFrom(
                foregroundColor: AppPalette.textSecondary,
              ),
              confirmButtonStyle: TextButton.styleFrom(
                foregroundColor: AppPalette.candyBlue,
              ),
            ),
          ),
          child: child!,
        ),
      );
    },
  );
}

/// One consistent timing step for every meetup, "today" included (ADR-016)
/// — a date picker (defaulting to today) plus two time pickers, "From" and
/// "To", replacing the old today-vs-later branching. Client-side validation
/// only rejects `to <= from` on the *same* picked date — a window is kept
/// to a single calendar day at entry time (ADR-016 doesn't require this at
/// the data/display level, [formatMeetupWindow] already renders a
/// midnight-crossing window correctly if one ever exists, but this simple
/// two-time picker has no second date to express "ends tomorrow" without
/// either silently reinterpreting a likely AM/PM typo as a 20+-hour window
/// or adding a second date field — deferred, not in ADR-016's scope).
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
  late DateTime _date = widget.initialStart ?? DateTime.now();
  TimeOfDay? _from;
  TimeOfDay? _to;

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

  bool get _rangeValid {
    if (_from == null || _to == null) return false;
    final fromMinutes = _from!.hour * 60 + _from!.minute;
    final toMinutes = _to!.hour * 60 + _to!.minute;
    return toMinutes > fromMinutes;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date.isBefore(now) ? now : _date,
      firstDate: now,
      lastDate: now.add(const Duration(days: 90)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickFrom() async {
    final picked = await _pickMeetupTime(context, _from ?? TimeOfDay.now());
    if (picked != null) setState(() => _from = picked);
  }

  Future<void> _pickTo() async {
    final picked = await _pickMeetupTime(
      context,
      _to ?? _from ?? TimeOfDay.now(),
    );
    if (picked != null) setState(() => _to = picked);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StepTitle('When should it happen?'),
        _ChoiceCard(
          icon: Icons.event_rounded,
          title: 'DATE',
          subtitle:
              '${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}',
          onTap: _pickDate,
        ),
        const SizedBox(height: 12),
        _ChoiceCard(
          icon: Icons.schedule_rounded,
          title: 'FROM',
          subtitle: _from == null
              ? 'Choose a start time'
              : _from!.format(context),
          onTap: _pickFrom,
        ),
        const SizedBox(height: 12),
        _ChoiceCard(
          icon: Icons.schedule_rounded,
          title: 'TO',
          subtitle: _to == null ? 'Choose an end time' : _to!.format(context),
          onTap: _pickTo,
        ),
        if (_from != null && _to != null && !_rangeValid) ...[
          const SizedBox(height: 10),
          Text(
            'End time must be after the start time.',
            style: TextStyle(color: AppPalette.danger, fontSize: 12),
          ),
        ],
        const SizedBox(height: 20),
        PrimaryButton(
          label: 'CONTINUE',
          onPressed: _rangeValid
              ? () => widget.onPick(
                  DateTime(
                    _date.year,
                    _date.month,
                    _date.day,
                    _from!.hour,
                    _from!.minute,
                  ),
                  DateTime(
                    _date.year,
                    _date.month,
                    _date.day,
                    _to!.hour,
                    _to!.minute,
                  ),
                )
              : null,
        ),
      ],
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
        FlatCard(
          radius: 12,
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _StepperButton(
                icon: Icons.remove_rounded,
                onTap: _capacity > _min
                    ? () => setState(() => _capacity--)
                    : null,
              ),
              Text(
                '$_capacity',
                style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.w800,
                  color: AppPalette.textPrimary,
                ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StepTitle('Review & confirm'),
        FlatCard(
          radius: 12,
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _reviewRow(Icons.category_outlined, 'Intent', intent.label),
              const _ReviewDivider(),
              _reviewRow(
                Icons.schedule_rounded,
                'When',
                formatMeetupWindow(windowStart, windowEnd),
              ),
              const _ReviewDivider(),
              _reviewRow(Icons.place_outlined, 'Location', locationLabel),
              const _ReviewDivider(),
              _reviewRow(Icons.people_outline, 'Capacity', '$capacity'),
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

  Widget _reviewRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      // Row grows in height instead of overflowing horizontally when
      // `value` is long (e.g. a full address for Location) — the previous
      // Spacer()-plus-unconstrained-Text gave the value no width limit at
      // all, so anything past the row's remaining space overflowed past
      // the card's edge rather than wrapping.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppPalette.candyBlue),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
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
