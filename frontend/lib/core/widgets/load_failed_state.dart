import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/services/auth_service.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';
import 'package:professional_connections_platform/core/theme/app_palette.dart';
import 'package:professional_connections_platform/core/utils/location.dart';
import 'package:professional_connections_platform/core/widgets/app_icons.dart';
import 'package:professional_connections_platform/core/widgets/faded_picture.dart';
import 'package:professional_connections_platform/core/widgets/primary_button.dart';

/// What kind of failure a page ran into, decided from the error it caught,
/// so the message can say the one thing the person can act on.
enum LoadFailureKind { offline, permission, location, server }

/// Maps any caught error to a [LoadFailureKind] and the sentence to show.
/// The wording never repeats what the server said: it is the app's own
/// voice, one line, no jargon.
class LoadFailure {
  const LoadFailure(this.kind, this.title, this.message);

  final LoadFailureKind kind;
  final String title;
  final String message;

  factory LoadFailure.of(Object? error) {
    if (error is MeetupOfflineException) {
      // The service already told "no connection" from "too slow"; keep
      // its sentence.
      return LoadFailure(
        LoadFailureKind.offline,
        'You look offline',
        error.message,
      );
    }
    if (error is AuthNetworkException ||
        error is SocketException ||
        error is TimeoutException) {
      return const LoadFailure(
        LoadFailureKind.offline,
        'You look offline',
        'We could not reach TieHere. Check your connection and try again.',
      );
    }
    if (error is MeetupForbiddenException) {
      return const LoadFailure(
        LoadFailureKind.permission,
        'Not available for your account yet',
        'This part of TieHere opens up as you verify your account.',
      );
    }
    if (error is LocationUnavailableException) {
      return LoadFailure(
        LoadFailureKind.location,
        'We need your location for this',
        error.message,
      );
    }
    return const LoadFailure(
      LoadFailureKind.server,
      'Something went wrong on our side',
      'We could not load this right now. Give it a moment and try again.',
    );
  }
}

/// The picture-and-a-line a page shows when it could not load: the rainy
/// street scene faded into the page's own ground, the failure's title and
/// sentence, and a RETRY. One widget for every page so a failed load looks
/// the same wherever it happens, and so it looks like part of the app
/// rather than an error dialog.
///
/// [compact] is for a failure inside a card or section rather than a whole
/// page: a smaller picture and tighter spacing.
class LoadFailedState extends StatelessWidget {
  const LoadFailedState({
    super.key,
    required this.failure,
    this.onRetry,
    this.retryLabel = 'Try again',
    this.retryIcon = AppIcons.refresh,
    this.compact = false,
    this.extraAction,
  });

  /// From the caught error: `LoadFailedState(failure: LoadFailure.of(e))`.
  final LoadFailure failure;
  final VoidCallback? onRetry;
  final String retryLabel;

  /// The glyph on the primary button; a retry arrow unless the action is
  /// something else (opening settings, say).
  final String retryIcon;
  final bool compact;

  /// An optional second control under RETRY (open settings, say).
  final Widget? extraAction;

  @override
  Widget build(BuildContext context) {
    final pictureHeight = compact ? 120.0 : 190.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, compact ? 8 : 28, 24, compact ? 8 : 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadedPicture(
            asset: 'assets/images/states/conn_lost.jpg',
            height: pictureHeight,
          ),
          SizedBox(height: compact ? 12 : 18),
          Text(
            failure.title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: compact ? 15 : 17,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Text(
              failure.message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ),
          if (onRetry != null) ...[
            SizedBox(height: compact ? 14 : 20),
            SizedBox(
              width: 200,
              child: PrimaryButton(
                label: retryLabel,
                icon: retryIcon,
                height: 44,
                onPressed: onRetry,
              ),
            ),
          ],
          if (extraAction != null) ...[const SizedBox(height: 8), extraAction!],
        ],
      ),
    );
  }
}

/// The scene with its edges dissolved into the page ground, so it sits in
/// the layout like a watercolour rather than a photo in a frame.
/// Keeps a page's skeleton up for a moment after its load has failed, then
/// shows the failure. A load that fails in 200 ms would otherwise flash
/// from placeholder to error before the eye has settled; holding the
/// skeleton for [holdFor] makes the page read as "tried, then could not"
/// instead of "broke on arrival". The hold starts when this widget appears,
/// which is when the failure arrived.
class SkeletonThenFailure extends StatefulWidget {
  const SkeletonThenFailure({
    super.key,
    required this.skeleton,
    required this.failure,
    this.holdFor = const Duration(milliseconds: 1200),
  });

  final Widget skeleton;
  final Widget failure;
  final Duration holdFor;

  @override
  State<SkeletonThenFailure> createState() => _SkeletonThenFailureState();
}

class _SkeletonThenFailureState extends State<SkeletonThenFailure> {
  Timer? _timer;
  bool _showFailure = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.holdFor, () {
      if (mounted) setState(() => _showFailure = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: _showFailure
          ? KeyedSubtree(key: const ValueKey('failure'), child: widget.failure)
          : KeyedSubtree(
              key: const ValueKey('skeleton'),
              child: widget.skeleton,
            ),
    );
  }
}
