import 'package:flutter/material.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/widgets/app_tag.dart';

/// A compact, colour-coded lifecycle-status pill (ADR-016 addendum,
/// 2026-08-20) — every card that renders a [Meetup] shows this.
///
/// # IT IS AN [AppTag] NOW, AND THAT FIXED A CONTRAST BUG
///
/// This drew its own `Container`: a 10%-alpha fill with the SAME colour at
/// full strength as the 10px label. On the light theme that put
/// `AppPalette.verified` (#2DAA45) on a near-white ground at **2.4:1** —
/// a third of what AA asks for 10px text — and the cancelled variant was
/// not much better.
///
/// [AppTag] resolves a tone to a tint AND a separately-chosen readable
/// foreground ([AppPalette.verifiedText], [AppPalette.dangerOnTint]), so
/// the problem cannot come back by someone picking a fill they liked.
///
/// The mapping is the interesting part and is deliberate:
///
///  * `open` → [AppTone.success], because it is an invitation.
///  * `full` → [AppTone.accent], NOT danger. A full meetup is not a
///    failure; it is a normal, common, successful state that simply is not
///    available to you. Red would read as an error the user caused.
///  * `cancelled` → [AppTone.danger].
///  * `completed` → [AppTone.neutral]. It is history.
class MeetupStatusBadge extends StatelessWidget {
  const MeetupStatusBadge({super.key, required this.status, this.onSurface});

  final MeetupStatus status;

  /// See [AppTag.onSurface].
  final Color? onSurface;

  @override
  Widget build(BuildContext context) {
    final (label, tone) = switch (status) {
      MeetupStatus.open => ('Open', AppTone.success),
      MeetupStatus.full => ('Full', AppTone.accent),
      MeetupStatus.cancelled => ('Cancelled', AppTone.danger),
      MeetupStatus.completed => ('Completed', AppTone.neutral),
    };
    return AppTag(label, tone: tone, onSurface: onSurface);
  }
}
