import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/professional_avatar.dart';
import 'package:professional_connections_platform/features/notifications/notifications_page.dart';

class HomeHeader extends StatelessWidget {
  const HomeHeader({super.key, required this.userName, this.imageUrl});

  final String userName;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
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
                        color: AppPalette.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      userName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppPalette.textPrimary,
                        // 22 was competing with the meetup titles further
                        // down the page: the user's own name is the one
                        // thing on Home they already know.
                        fontSize: 19,
                        height: 1.15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                      ),
                    ),
                  ],
                ),
              ),
              _NotificationBell(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const NotificationsPage(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              ProfessionalAvatar(
                size: 40,
                name: userName,
                imageUrl: imageUrl,
                // The one avatar in the app that is unambiguously the
                // viewer's own, which is what the ring and the dot mean.
                ring: true,
                showPresenceDot: true,
              ),
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
      // opaque so the padding around the glyph is part of the target — a
      // 24px icon alone is under the 44px minimum tap size.
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.all(8.0),
        child: AppIcon(
          AppIcons.bell,
          size: 23,
          color: AppPalette.textSecondary,
        ),
      ),
    );
  }
}
