import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/services/photo_picker.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/app_sheet.dart';

/// What the person chose on the photo sheet.
enum PhotoAction { camera, library, remove }

extension PhotoActionSource on PhotoAction {
  /// The picker source, or null for [PhotoAction.remove].
  PhotoSource? get source => switch (this) {
    PhotoAction.camera => PhotoSource.camera,
    PhotoAction.library => PhotoSource.library,
    PhotoAction.remove => null,
  };
}

/// "Take photo", "Choose from library", and "Remove photo" when there is one
/// (plan 2.1).
Future<PhotoAction?> showProfilePhotoSheet(
  BuildContext context, {
  required bool hasPhoto,
}) {
  return showAppSheet<PhotoAction>(
    context,
    builder: (sheetContext) => AppSheet(
      title: 'Profile photo',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Option(
            icon: AppIcons.camera,
            label: 'Take photo',
            onTap: () => Navigator.pop(sheetContext, PhotoAction.camera),
          ),
          _Option(
            icon: AppIcons.image,
            label: 'Choose from library',
            onTap: () => Navigator.pop(sheetContext, PhotoAction.library),
          ),
          if (hasPhoto)
            _Option(
              icon: AppIcons.trash,
              label: 'Remove photo',
              color: AppPalette.danger,
              onTap: () => Navigator.pop(sheetContext, PhotoAction.remove),
            ),
        ],
      ),
    ),
  );
}

class _Option extends StatelessWidget {
  const _Option({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final String icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
          child: Row(
            children: [
              AppIcon(icon, size: 20, color: color ?? AppPalette.candyBlue),
              const SizedBox(width: 14),
              Text(
                label,
                style: TextStyle(
                  color: color ?? AppPalette.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
