part of 'profile_page.dart';

/// The top of the profile, in the shape of the reference design: a flat
/// tinted band that runs edge to edge and under the status bar, rounded
/// only at the bottom, with the edit control as a round button in its
/// corner, the person in the middle with a ring around their picture and a
/// small status dot, their name and standing under it, and their numbers
/// in a quiet row at the bottom. The band is the palette's own deepBlue
/// tint (pale in light, deep in dark): one colour, no gradient.
class _ProfileHero extends StatelessWidget {
  const _ProfileHero({
    required this.profile,
    required this.onEditName,
    required this.stats,
    this.onChangePhoto,
    this.photoBusy = false,
  });

  final UserProfile? profile;
  final VoidCallback? onEditName;
  final Widget stats;

  /// Tapping the avatar (plan 2.1). Null until the profile has loaded.
  final VoidCallback? onChangePhoto;

  /// True while a new photo is uploading or one is being removed.
  final bool photoBusy;

  @override
  Widget build(BuildContext context) {
    final fullName = profile?.fullName;
    final displayName = (fullName == null || fullName.isEmpty)
        ? 'Member'
        : fullName;
    final photo = (profile?.profilePhotoUrl.isNotEmpty ?? false)
        ? profile!.profilePhotoUrl
        : null;
    final standing = switch (profile?.trustLevel) {
      null => 'Signing you in',
      0 => 'New here',
      1 => 'Getting verified',
      2 => 'Verified member',
      _ => 'Verified professional',
    };

    final statusBar = MediaQuery.paddingOf(context).top;
    return Container(
      padding: EdgeInsets.fromLTRB(20, statusBar + 8, 20, 22),
      decoration: BoxDecoration(
        color: AppPalette.deepBlue,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(32)),
      ),
      child: Column(
        children: [
          // The one control on the card, in the corner where the
          // reference keeps it. Full name has no row of its own in the
          // VERIFICATION section (ADR-023 §5): one field, no OTP.
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (onEditName != null)
                _RoundControl(
                  icon: AppIcons.edit,
                  onTap: onEditName!,
                  label: 'Edit your name',
                )
              else
                const SizedBox(height: 44),
            ],
          ),
          const SizedBox(height: 2),
          // The ring and the presence dot are ProfessionalAvatar's job.
          // This screen used to hand-roll both in a Stack, which is why
          // the Home header's avatar and this one stopped matching the
          // moment one of them changed: Home went to a flat blue band and
          // this kept the old blue-to-green gradient.
          Semantics(
            button: onChangePhoto != null,
            label: 'Change your photo',
            child: GestureDetector(
              key: const Key('profile-avatar'),
              onTap: photoBusy ? null : onChangePhoto,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  ProfessionalAvatar(
                    size: 104,
                    name: fullName,
                    imageUrl: photo,
                    ring: true,
                    showPresenceDot: true,
                  ),
                  if (photoBusy)
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: AppPalette.candyBlue,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: AppPalette.textPrimary,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            standing,
            style: TextStyle(color: AppPalette.textSecondary, fontSize: 14),
          ),
          const SizedBox(height: 12),
          VerificationBadges(
            trustLevel: profile?.trustLevel ?? 0,
            // Self-view only (ADR-023 §2): the Official chip follows the
            // work-email step on its own, ahead of the full Level 3.
            workEmailVerifiedOverride: profile?.workEmailVerified,
          ),
          const SizedBox(height: 20),
          stats,
        ],
      ),
    );
  }
}

/// The profile's own shape as placeholders: the band with a circle and
/// two lines, three stat boxes, then a card of four rows.
class _ProfileSkeleton extends StatelessWidget {
  const _ProfileSkeleton();

  @override
  Widget build(BuildContext context) {
    final statusBar = MediaQuery.paddingOf(context).top;
    return SkeletonLoader(
      child: ListView(
        padding: EdgeInsets.zero,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          Container(
            padding: EdgeInsets.fromLTRB(20, statusBar + 52, 20, 22),
            decoration: BoxDecoration(
              color: AppPalette.deepBlue,
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(32),
              ),
            ),
            child: Column(
              children: [
                const SkeletonBox(width: 116, height: 116, radius: 58),
                const SizedBox(height: 18),
                const SkeletonBox(width: 180, height: 22, opacity: 0.1),
                const SizedBox(height: 10),
                const SkeletonBox(width: 120, height: 13),
                const SizedBox(height: 26),
                Row(
                  children: [
                    for (var i = 0; i < 3; i++) ...[
                      if (i > 0) const SizedBox(width: 12),
                      const Expanded(
                        child: SkeletonBox(
                          width: double.infinity,
                          height: 68,
                          radius: 16,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: SkeletonBox(width: 110, height: 11),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: FlatCard(
              radius: 18,
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  for (var i = 0; i < 4; i++)
                    Padding(
                      padding: EdgeInsets.only(bottom: i == 3 ? 0 : 18),
                      child: const Row(
                        children: [
                          SkeletonBox(width: 40, height: 40, radius: 12),
                          SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SkeletonBox(width: 120, height: 13),
                                SizedBox(height: 6),
                                SkeletonBox(width: 80, height: 11),
                              ],
                            ),
                          ),
                          SkeletonBox(width: 22, height: 22, radius: 11),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
