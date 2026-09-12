import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:professional_connections_platform/core/services/http_meetup_service.dart';
import 'package:professional_connections_platform/core/services/meetup_service.dart';

const _baseUrl = 'http://localhost:8080';

HttpMeetupService _serviceWith(http.Client client) => HttpMeetupService(
  httpClient: client,
  baseUrl: _baseUrl,
  getAccessToken: () async => 'token',
);

/// A realistic gateway safety-state body, matching
/// `backend/internal/gateway/handlers/meetups.go`'s `safetyStateResponse`
/// field-for-field.
String _safetyStateBody({List<String> sharedWith = const []}) => jsonEncode({
  'meetup_id': 'meetup-1',
  'checklist_ack_at_unix_seconds': 1757000000,
  'live_location_opt_in': false,
  'checked_in_at_unix_seconds': 1757003600,
  'shared_with_contact_ids': sharedWith,
});

/// # WHY THIS FILE EXISTS
///
/// `HttpMeetupService` had no response-parsing tests. Every widget test
/// builds model objects directly through `ScriptedMeetupService`, so the
/// decode path from a real HTTP body was never exercised — which is how
/// `shared_with_contact_ids` shipped absent from `SafetyState.fromJson`
/// while every other layer of the feature was correct.
///
/// A model-only test would not catch a mismatch between the model's field
/// and a differently-shaped service-layer wrapper, so these go through the
/// real service.
void main() {
  group('getSafetyState', () {
    test(
      'parses the contacts already told from a real response body',
      () async {
        final client = MockClient((request) async {
          expect(
            request.url.toString(),
            '$_baseUrl/v1/meetups/meetup-1/safety',
          );
          return http.Response(
            _safetyStateBody(sharedWith: ['contact-1', 'contact-2']),
            200,
            headers: {'content-type': 'application/json'},
          );
        });

        final state = await _serviceWith(client).getSafetyState('meetup-1');

        expect(
          state.sharedWithContactIds,
          ['contact-1', 'contact-2'],
          reason:
              'this is the field whose absence made the share-confirmation '
              'mechanism dead in production',
        );
        expect(state.sharedWithAnyContact, isTrue);
        expect(state.checklistAcknowledged, isTrue);
        expect(state.checkedIn, isTrue);
      },
    );

    test('an empty list reads as told nobody', () async {
      final client = MockClient(
        (request) async => http.Response(
          _safetyStateBody(),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );

      final state = await _serviceWith(client).getSafetyState('meetup-1');

      expect(state.sharedWithContactIds, isEmpty);
      expect(state.sharedWithAnyContact, isFalse);
    });
  });

  group('shareWithContacts', () {
    test(
      'posts the chosen ids and parses the updated state back — the response '
      'of the share itself is what the screen renders immediately after',
      () async {
        final client = MockClient((request) async {
          expect(
            request.url.toString(),
            '$_baseUrl/v1/meetups/meetup-1/safety/share',
          );
          expect(request.method, 'POST');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['contact_ids'], ['contact-1']);

          return http.Response(
            _safetyStateBody(sharedWith: ['contact-1']),
            200,
            headers: {'content-type': 'application/json'},
          );
        });

        final state = await _serviceWith(
          client,
        ).shareWithContacts('meetup-1', ['contact-1']);

        expect(
          state.sharedWithContactIds,
          ['contact-1'],
          reason:
              'the share response drives the "Told N trusted contacts" text '
              'without a refetch, so it must decode too',
        );
      },
    );
  });

  // A session that has gone missing from storage (secure-storage loss across
  // a reinstall, a cleared keychain) makes getAccessToken return null. Sending
  // the request anyway, minus the Authorization header, buys a guaranteed 401
  // that no refresh can fix — there is no refresh token left to send. Fail
  // before the socket is opened, with the same exception a real 401 maps to,
  // so AppShell's session-expired listener lands the user on LandingPage
  // instead of a provider retrying an unauthenticated call forever.
  group('missing session', () {
    test(
      'throws MeetupSessionExpiredException without sending a request',
      () async {
        var requestsSent = 0;
        final client = MockClient((request) async {
          requestsSent++;
          return http.Response('{}', 200);
        });
        final service = HttpMeetupService(
          httpClient: client,
          baseUrl: _baseUrl,
          getAccessToken: () async => null,
        );

        await expectLater(
          service.listOpenMeetups(viewerLat: 0, viewerLng: 0),
          throwsA(isA<MeetupSessionExpiredException>()),
        );
        expect(requestsSent, 0);
      },
    );
  });
}
