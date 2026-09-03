import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/theme/app_palette.dart';

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 10,
        letterSpacing: 2.2,
        fontWeight: FontWeight.w600,
        color: AppPalette.textSecondary,
      ),
    );
  }
}
