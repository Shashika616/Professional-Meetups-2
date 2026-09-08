import 'package:flutter_test/flutter_test.dart';

import 'package:professional_connections_platform/core/models/intent_type.dart';
import 'package:professional_connections_platform/core/models/meetup.dart';

Meetup _meetup({required DateTime windowStart, required DateTime windowEnd}) =>
    Meetup(
      id: 'meetup-1',
      hostUserId: 'host-1',
      hostFullName: 'Grace Hopper',
      hostTrustLevel: 2,
      intent: IntentType.coffee,
      windowStart: windowStart,
      windowEnd: windowEnd,
      locationLat: 6.9271,
      locationLng: 79.8612,
      locationLabel: 'Colombo Fort Cafe',
      capacity: 4,
      acceptedCount: 0,
      status: MeetupStatus.open,
      createdAt: DateTime.now(),
    );

void main() {
  group('formatMeetupWindow / Meetup.formattedWindow (ADR-016)', () {
    test('today, same AM/PM period — period shown once, at the end', () {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day, 15, 0);
      final end = DateTime(now.year, now.month, now.day, 17, 0);

      expect(formatMeetupWindow(start, end), 'Today, 3:00–5:00 PM');
      expect(
        _meetup(windowStart: start, windowEnd: end).formattedWindow,
        'Today, 3:00–5:00 PM',
      );
    });

    test('a future date — shows the abbreviated month and day', () {
      final start = DateTime(2026, 8, 22, 18, 0);
      final end = DateTime(2026, 8, 22, 20, 0);

      expect(formatMeetupWindow(start, end), 'Aug 22, 6:00–8:00 PM');
    });

    test(
      'crossing AM/PM within the same day — both times carry their own suffix',
      () {
        final start = DateTime(2026, 8, 22, 11, 30);
        final end = DateTime(2026, 8, 22, 13, 30);

        expect(formatMeetupWindow(start, end), 'Aug 22, 11:30 AM–1:30 PM');
      },
    );

    test(
      'crossing midnight — allowed (ADR-016 doesn\'t require same-day), '
      'both times carry their own AM/PM suffix, date shown is the start date',
      () {
        final start = DateTime(2026, 8, 22, 22, 0);
        final end = DateTime(2026, 8, 23, 1, 0);

        expect(formatMeetupWindow(start, end), 'Aug 22, 10:00 PM–1:00 AM');
      },
    );

    test('noon and midnight format as 12, not 0', () {
      final noon = DateTime(2026, 8, 22, 12, 0);
      final afternoon = DateTime(2026, 8, 22, 13, 0);
      expect(formatMeetupWindow(noon, afternoon), 'Aug 22, 12:00–1:00 PM');

      final midnight = DateTime(2026, 8, 22, 0, 0);
      final earlyMorning = DateTime(2026, 8, 22, 1, 0);
      expect(
        formatMeetupWindow(midnight, earlyMorning),
        'Aug 22, 12:00–1:00 AM',
      );
    });
  });

  /// # WHY THIS GROUP EXISTS
  ///
  /// `SafetyState` had NO fromJson coverage at all, and that is precisely how
  /// a shipped feature ended up doing nothing: `shared_with_contact_ids` was
  /// added to the model, the constructor, the backend response and the UI —
  /// but never to `fromJson`. It fell back to its `const []` default on every
  /// real HTTP response, so "Told N trusted contacts" and the picker's
  /// "Already told" state could never appear in production.
  ///
  /// Every widget test built `SafetyState` objects directly through
  /// `ScriptedMeetupService`, so none of them ever exercised the decode path.
  /// These do.
  group('SafetyState.fromJson', () {
    test('parses a full safety-state response', () {
      final state = SafetyState.fromJson({
        'meetup_id': 'meetup-1',
        'checklist_ack_at_unix_seconds': 1757000000,
        'live_location_opt_in': true,
        'checked_in_at_unix_seconds': 1757003600,
        'shared_with_contact_ids': ['contact-1', 'contact-2'],
      });

      expect(state.meetupId, 'meetup-1');
      expect(state.checklistAcknowledged, isTrue);
      expect(state.liveLocationOptIn, isTrue);
      expect(state.checkedIn, isTrue);
      expect(state.sharedWithContactIds, ['contact-1', 'contact-2']);
      expect(state.sharedWithAnyContact, isTrue);
    });

    test('reads shared_with_contact_ids — the field whose absence made the '
        'whole share-confirmation mechanism dead on arrival', () {
      final state = SafetyState.fromJson({
        'meetup_id': 'meetup-1',
        'shared_with_contact_ids': ['contact-1'],
      });

      expect(
        state.sharedWithContactIds,
        ['contact-1'],
        reason:
            'without this the UI can never show that a share happened, and '
            'a safety action you cannot verify is one you cannot rely on',
      );
    });

    test('a declined state carries its reason', () {
      final state = SafetyState.fromJson({
        'meetup_id': 'meetup-1',
        'declined_at_unix_seconds': 1757000000,
        'decline_reason': 'Something came up',
        'shared_with_contact_ids': <String>[],
      });

      expect(state.declined, isTrue);
      expect(state.declineReason, 'Something came up');
      expect(state.checkedIn, isFalse);
    });

    test('defaults sensibly when optional fields are absent', () {
      final state = SafetyState.fromJson({'meetup_id': 'meetup-1'});

      expect(state.checklistAcknowledged, isFalse);
      expect(state.checkedIn, isFalse);
      expect(state.declined, isFalse);
      expect(state.liveLocationOptIn, isFalse);
      // An older server that omits the key entirely must read as "told
      // nobody", not crash.
      expect(state.sharedWithContactIds, isEmpty);
      expect(state.sharedWithAnyContact, isFalse);
    });

    test('an explicitly empty list means told nobody, and does not throw', () {
      final state = SafetyState.fromJson({
        'meetup_id': 'meetup-1',
        'shared_with_contact_ids': <dynamic>[],
      });

      expect(state.sharedWithContactIds, isEmpty);
    });
  });
}
