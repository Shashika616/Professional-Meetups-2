import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/widgets/meetup_status_badge.dart';

void main() {
  group('MeetupStatusBadge (ADR-016 addendum, 2026-08-20)', () {
    for (final (status, label) in [
      (MeetupStatus.open, 'OPEN'),
      (MeetupStatus.full, 'FULL'),
      (MeetupStatus.cancelled, 'CANCELLED'),
      (MeetupStatus.completed, 'COMPLETED'),
    ]) {
      testWidgets('renders $label for MeetupStatus.$status', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: MeetupStatusBadge(status: status)),
          ),
        );

        expect(find.text(label), findsOneWidget);
      });
    }
  });
}
