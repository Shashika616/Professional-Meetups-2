import 'package:flutter/widgets.dart';

import 'package:professional_connections_platform/core/analytics/analytics.dart';
import 'package:professional_connections_platform/core/analytics/event_names.g.dart';
import 'package:professional_connections_platform/core/analytics/flow_tracker.dart';

/// A funnel whose progress is state the page already shows (plan 29E): the
/// verification checklist and hosting unlock, where a step is done when the
/// profile says so.
///
/// Starts [flowId] (at [firstStep]) when it first appears. A step in
/// [doneSteps] that was not done before is reported completed: steps done
/// before the page opened are not (they belong to an earlier visit), except
/// [firstStep], which is reported done at once if it already is. When
/// [completed] turns true the flow completes; leaving before that abandons
/// it.
class TrackedFlow extends StatefulWidget {
  const TrackedFlow({
    super.key,
    required this.flowId,
    required this.child,
    this.firstStep,
    this.doneSteps = const {},
    this.completed = false,
  });

  final String flowId;
  final String? firstStep;
  final Set<String> doneSteps;
  final bool completed;
  final Widget child;

  @override
  State<TrackedFlow> createState() => _TrackedFlowState();
}

class _TrackedFlowState extends State<TrackedFlow> {
  late final FlowTracker _flow = Analytics.instance.flow(widget.flowId);
  late Set<String> _done = Set.of(widget.doneSteps);
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _flow.start();
    final first = widget.firstStep;
    if (first != null) {
      _flow.stepViewed(first);
      // The first step already done on arrival is passed straight through,
      // so the funnel does not show it as where people stopped.
      if (widget.doneSteps.contains(first)) _flow.stepCompleted(first);
    }
    _completed = widget.completed;
    // Opened with the goal already reached (it can be reached from
    // elsewhere): nothing left to measure.
    if (_completed) _flow.complete();
  }

  @override
  void didUpdateWidget(TrackedFlow old) {
    super.didUpdateWidget(old);
    for (final step in widget.doneSteps.difference(_done)) {
      _flow.stepCompleted(step);
    }
    _done = Set.of(widget.doneSteps);
    if (widget.completed && !_completed) {
      _completed = true;
      _flow.complete();
    }
  }

  @override
  void dispose() {
    _flow.abandon(AnalyticsValue.flowAbandonedReasonBack);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
