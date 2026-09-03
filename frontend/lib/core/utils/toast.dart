import 'dart:async';

import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

enum ToastType { success, info, warning, error, locked }

class _ToastMeta {
  const _ToastMeta(this.icon, this.color);

  final IconData icon;
  final Color color;
}

class ToastService {
  ToastService._();

  static OverlayEntry? _entry;
  static int _currentId = 0;

  static void show(
    BuildContext context,
    String message, {
    ToastType type = ToastType.info,
  }) {
    final overlay = Overlay.of(context);
    _currentId += 1;
    final id = _currentId;

    _entry?.remove();
    _entry = OverlayEntry(
      builder: (_) => _ToastCard(
        message: message,
        type: type,
        onDismiss: () {
          // Only dismiss if this toast is still the active one.
          if (_currentId == id) {
            _entry?.remove();
            _entry = null;
          }
        },
      ),
    );
    overlay.insert(_entry!);
  }
}

class _ToastCard extends StatefulWidget {
  const _ToastCard({
    required this.message,
    required this.type,
    required this.onDismiss,
  });

  final String message;
  final ToastType type;
  final VoidCallback onDismiss;

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _holdTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _controller.forward();
    _holdTimer = Timer(const Duration(milliseconds: 2400), _dismiss);
  }

  void _dismiss() {
    _holdTimer?.cancel();
    _controller.reverse().then((_) => widget.onDismiss());
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  _ToastMeta _meta(ToastType type) => switch (type) {
    ToastType.success => _ToastMeta(
      Icons.verified_rounded,
      AppPalette.verified,
    ),
    ToastType.info => _ToastMeta(Icons.info_rounded, AppPalette.candyBlue),
    ToastType.warning => const _ToastMeta(
      Icons.warning_amber_rounded,
      Color(0xFFF2B84B),
    ),
    ToastType.error => _ToastMeta(Icons.error_rounded, AppPalette.danger),
    ToastType.locked => _ToastMeta(Icons.lock_rounded, AppPalette.steelBlue),
  };

  @override
  Widget build(BuildContext context) {
    final double topPadding = MediaQuery.of(context).padding.top;
    final meta = _meta(widget.type);

    return Positioned(
      top: topPadding + 8,
      left: 16,
      right: 16,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, -1.4), end: Offset.zero)
            .animate(
              CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
            ),
        child: FadeTransition(
          opacity: _controller,
          child: GestureDetector(
            onTap: _dismiss,
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: AppPalette.card.withValues(alpha: 0.96),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: meta.color.withValues(alpha: 0.45)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.45),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: meta.color.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(meta.icon, size: 16, color: meta.color),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.message,
                        style: TextStyle(
                          color: AppPalette.textPrimary,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
