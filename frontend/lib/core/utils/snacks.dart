import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/utils/toast.dart';

/// App-wide notification helper.
/// Defaults to [ToastType.info]; pass a type for semantic icons and colors.
void showSnack(
  BuildContext context,
  String message, {
  ToastType type = ToastType.info,
}) {
  ToastService.show(context, message, type: type);
}
