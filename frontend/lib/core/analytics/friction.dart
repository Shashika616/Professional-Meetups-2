import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';

import 'package:professional_connections_platform/core/analytics/analytics.dart';
import 'package:professional_connections_platform/core/analytics/event_names.g.dart';

/// Rage taps (plan 29 §4.1): three or more taps within one second inside a
/// 24 px radius with no screen change in between. Reported once per burst,
/// as soon as the third tap lands.
class RageTapDetector {
  RageTapDetector({
    required this.generation,
    required this.onRageTap,
    this.window = const Duration(seconds: 1),
    this.radius = 24,
    this.threshold = 3,
  });

  /// The navigation generation now ([Analytics.navigationGeneration]).
  final int Function() generation;
  final void Function(int taps) onRageTap;
  final Duration window;
  final double radius;
  final int threshold;

  final List<(DateTime, Offset)> _taps = [];
  int _generation = -1;
  bool _reported = false;

  void tap(Offset position) {
    final now = clock.now();
    final gen = generation();
    final first = _taps.isEmpty ? null : _taps.first;
    final burstOver =
        gen != _generation ||
        first == null ||
        now.difference(first.$1) > window ||
        (position - first.$2).distance > radius;
    if (burstOver) {
      _taps.clear();
      _reported = false;
      _generation = gen;
    }
    _taps.add((now, position));
    if (!_reported && _taps.length >= threshold) {
      _reported = true;
      onRageTap(_taps.length);
    }
  }
}

/// Watches every pointer-down in the app for rage taps, without taking part
/// in hit testing (it never stops a tap reaching its target).
class RageTapListener extends StatefulWidget {
  const RageTapListener({super.key, required this.child});

  final Widget child;

  @override
  State<RageTapListener> createState() => _RageTapListenerState();
}

class _RageTapListenerState extends State<RageTapListener> {
  late final RageTapDetector _detector = RageTapDetector(
    generation: () => Analytics.instance.navigationGeneration,
    onRageTap: (taps) => Analytics.instance.record(
      AnalyticsEvent.rageTap,
      attributes: {AnalyticsAttribute.taps: taps},
    ),
  );

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (event) => _detector.tap(event.position),
    child: widget.child,
  );
}

/// Long dwell (plan 29 §4.1): a form step open for [after] without any
/// input. Reported once per step, then not again until [activity] or a new
/// [start].
class DwellWatcher {
  DwellWatcher({
    required this.onDwell,
    this.after = const Duration(seconds: 60),
  });

  final void Function(int durationMs) onDwell;
  final Duration after;

  Timer? _timer;
  bool _reported = false;

  /// The step is showing: start the clock.
  void start() {
    _reported = false;
    _arm();
  }

  /// The user did something: the clock starts again.
  void activity() {
    if (_reported) return;
    _arm();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(after, () {
      _reported = true;
      onDwell(after.inMilliseconds);
    });
  }
}

/// Wraps a form step: reports `long_dwell` when it sits for a minute with no
/// tap, scroll or key press inside it. A new [stepKey] restarts the watch
/// (the next step of a multi-step form).
class DwellTracker extends StatefulWidget {
  const DwellTracker({super.key, required this.child, this.stepKey});

  final Widget child;
  final Object? stepKey;

  @override
  State<DwellTracker> createState() => _DwellTrackerState();
}

class _DwellTrackerState extends State<DwellTracker> {
  late final DwellWatcher _watcher = DwellWatcher(
    onDwell: (ms) => Analytics.instance.record(
      AnalyticsEvent.longDwell,
      attributes: {AnalyticsAttribute.durationMs: ms},
    ),
  );

  @override
  void initState() {
    super.initState();
    _watcher.start();
  }

  @override
  void didUpdateWidget(DwellTracker old) {
    super.didUpdateWidget(old);
    if (old.stepKey != widget.stepKey) _watcher.start();
  }

  @override
  void dispose() {
    _watcher.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (_) => _watcher.activity(),
    child: NotificationListener<ScrollNotification>(
      onNotification: (_) {
        _watcher.activity();
        return false;
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (node, event) {
          _watcher.activity();
          return KeyEventResult.ignored;
        },
        child: widget.child,
      ),
    ),
  );
}
