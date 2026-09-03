import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

/// The user's profile picture.
/// Shows initials on the brand gradient until a real photo URL arrives
/// from the backend. The brand mark (watch dial) is a separate widget: [AppIcon].
class ProfessionalAvatar extends StatelessWidget {
  const ProfessionalAvatar({
    super.key,
    this.name,
    this.imageUrl,
    this.size = 44,
  });

  final String? name;
  final String? imageUrl;
  final double size;

  /// Conservative upper bound for device pixel ratio, used to size the
  /// network image's decode cache (see the `cacheWidth`/`cacheHeight`
  /// comment in [build]).
  static const double _maxDevicePixelRatio = 3;

  String get _initials {
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return 'PC';
    final parts = trimmed.split(RegExp(r'\s+'));
    final first = parts.first.isNotEmpty ? parts.first[0].toUpperCase() : '';
    final last = parts.length > 1 ? parts.last[0].toUpperCase() : '';
    return '$first$last';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [AppPalette.deepBlue, AppPalette.steelBlue],
        ),
        border: Border.all(
          color: AppPalette.candyBlue.withValues(alpha: 0.4),
          width: 1.5,
        ),
      ),
      child: ClipOval(
        child: imageUrl != null
            ? Image.network(
                imageUrl!,
                fit: BoxFit.cover,
                // 2026-08-31 round-3 hardening, Fix 3: without
                // cacheWidth/cacheHeight, Image.network decodes and caches
                // a photo at its full source resolution even though it
                // only ever renders at [size] logical pixels here — wasteful
                // memory per unique avatar URL, more so with Fix 1's now-
                // longer scrollable lists. `_maxDevicePixelRatio` is a
                // fixed conservative upper bound rather than the actual
                // device's ratio (queryable via MediaQuery, but not worth
                // the per-build context dependency for a cache-size hint).
                cacheWidth: (size * _maxDevicePixelRatio).round(),
                cacheHeight: (size * _maxDevicePixelRatio).round(),
                errorBuilder: (context, error, stackTrace) => _initialsWidget(),
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : _initialsWidget(),
              )
            : _initialsWidget(),
      ),
    );
  }

  Widget _initialsWidget() {
    return Center(
      child: Text(
        _initials,
        style: TextStyle(
          color: AppPalette.candyBlue,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.36,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
