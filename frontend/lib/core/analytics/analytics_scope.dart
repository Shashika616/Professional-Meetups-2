import 'package:flutter/widgets.dart';

import 'package:professional_connections_platform/core/analytics/analytics.dart';
import 'package:professional_connections_platform/core/analytics/friction.dart';

/// Wraps the whole app (MaterialApp's builder): app lifecycle into sessions
/// and time on screen, and the rage-tap listener. Covers the signed-out
/// screens too, which is why it sits here rather than in the signed-in
/// shell.
class AnalyticsScope extends StatefulWidget {
  const AnalyticsScope({super.key, required this.child});

  final Widget child;

  @override
  State<AnalyticsScope> createState() => _AnalyticsScopeState();
}

class _AnalyticsScopeState extends State<AnalyticsScope>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      Analytics.instance.lifecycleChanged(state);

  @override
  Widget build(BuildContext context) => RageTapListener(child: widget.child);
}
