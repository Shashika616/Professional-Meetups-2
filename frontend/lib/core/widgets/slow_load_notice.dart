import 'dart:async';

import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// A one-line caption under a skeleton that says what the wait is for.
///
/// A shimmer with no words is fine for two seconds and a broken-looking
/// screen after ten. This is the sentence that turns the second case back
/// into "the app is working on it, and here is what it is waiting on".
///
/// The default constructor shows immediately (the caller has already
/// decided the wait is slow); [SlowLoadNotice.after] shows nothing until
/// [delay] has elapsed since it mounted, so a fast load never flashes it.
class SlowLoadNotice extends StatefulWidget {
  const SlowLoadNotice({super.key, required this.icon, required this.message})
    : delay = Duration.zero;

  const SlowLoadNotice.after({
    super.key,
    required this.delay,
    required this.icon,
    required this.message,
  });

  final Duration delay;
  final IconData icon;
  final String message;

  @override
  State<SlowLoadNotice> createState() => _SlowLoadNoticeState();
}

class _SlowLoadNoticeState extends State<SlowLoadNotice> {
  Timer? _timer;
  late bool _visible = widget.delay == Duration.zero;

  @override
  void initState() {
    super.initState();
    if (!_visible) {
      _timer = Timer(widget.delay, () {
        if (mounted) setState(() => _visible = true);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(widget.icon, size: 15, color: AppPalette.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.message,
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 12,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
