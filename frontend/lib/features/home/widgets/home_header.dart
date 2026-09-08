import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/snacks.dart';
import 'package:professional_connections_platform/core/utils/toast.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';

class HomeHeader extends StatelessWidget {
  const HomeHeader({super.key, required this.userName, this.imageUrl});

  final String userName;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _greeting(),
                      style: TextStyle(
                        color: AppPalette.textSecondary.withValues(alpha: 0.8),
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      userName,
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ],
                ),
              ),
              _NotificationBell(
                onTap: () => showSnack(
                  context,
                  'Notifications will arrive once the backend is live.',
                  type: ToastType.info,
                ),
              ),
              const SizedBox(width: 12),
              ProfessionalAvatar(size: 44, name: userName, imageUrl: imageUrl),
            ],
          ),
          // The two "Your Meetings"/"Requested Meetups" chips that used to
          // sit here are gone: that navigation is the Events bottom-nav tab
          // now, and a persistent tab is a better home for it than two
          // chips competing for space at the top of the browse feed.
        ],
      ),
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning,';
    if (hour < 17) return 'Good afternoon,';
    return 'Good evening,';
  }
}

class _NotificationBell extends StatelessWidget {
  const _NotificationBell({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.all(8.0),
        child: Icon(
          Icons.notifications_none_rounded,
          size: 24,
          color: AppPalette.textPrimary,
        ),
      ),
    );
  }
}
