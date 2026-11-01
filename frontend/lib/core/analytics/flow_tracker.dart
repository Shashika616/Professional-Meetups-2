import 'package:clock/clock.dart';

import 'package:professional_connections_platform/core/analytics/event_names.g.dart';

/// Emits one flow event: name, step and attributes.
typedef FlowSink =
    void Function(
      String event,
      String flowId,
      String? step,
      Map<String, Object> attributes,
    );

/// One funnel (plan 29 §4.1): `flow_started`, `flow_step_viewed`,
/// `flow_step_completed`, `flow_completed`, `flow_abandoned`, with the time
/// spent on each step and on the whole flow.
///
/// Safe to call in any order: viewing a step starts the flow if it has not
/// started, a step viewed twice in a row is reported once, and completing or
/// abandoning a flow that is not running does nothing. So a page can call
/// `abandon` from `dispose` without knowing whether it already completed.
class FlowTracker {
  FlowTracker(this.flowId, this._sink);

  /// A tracker that records nothing (the no-op analytics).
  FlowTracker.noop(this.flowId) : _sink = null;

  final String flowId;
  final FlowSink? _sink;

  bool _active = false;
  String? _step;
  DateTime? _startedAt;
  DateTime? _stepStartedAt;

  /// Whether the flow has started and not yet completed or been abandoned.
  bool get active => _active;

  /// The step showing now.
  String? get step => _step;

  void start() {
    if (_active) return;
    _active = true;
    _step = null;
    _startedAt = clock.now();
    _emit(AnalyticsEvent.flowStarted, null, const {});
  }

  void stepViewed(String step) {
    start();
    if (_step == step) return;
    _step = step;
    _stepStartedAt = clock.now();
    _emit(AnalyticsEvent.flowStepViewed, step, const {});
  }

  void stepCompleted(String step) {
    if (!_active) return;
    final since = _step == step ? _stepStartedAt : null;
    _emit(AnalyticsEvent.flowStepCompleted, step, {
      if (since != null) AnalyticsAttribute.durationMs: _ms(since),
    });
  }

  void complete() {
    if (!_active) return;
    _active = false;
    _emit(AnalyticsEvent.flowCompleted, _step, {
      AnalyticsAttribute.durationMs: _ms(_startedAt!),
    });
    _step = null;
  }

  /// [reason] is one of `AnalyticsValue.flowAbandonedReason*`.
  void abandon(String reason) {
    if (!_active) return;
    _active = false;
    _emit(AnalyticsEvent.flowAbandoned, _step, {
      AnalyticsAttribute.reason: reason,
    });
    _step = null;
  }

  void _emit(String event, String? step, Map<String, Object> attributes) =>
      _sink?.call(event, flowId, step, attributes);

  static int _ms(DateTime since) {
    final ms = clock.now().difference(since).inMilliseconds;
    // The registry caps durations at a day; a flow left open longer is
    // reported at the cap rather than dropped.
    return ms < 0 ? 0 : (ms > 86400000 ? 86400000 : ms);
  }
}
