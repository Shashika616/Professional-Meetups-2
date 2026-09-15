import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:professional_connections_platform/core/models/meetup.dart';
import 'package:professional_connections_platform/core/models/paged_result.dart';
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
  group('request deadline', () {
    test(
      'a request that never answers becomes MeetupOfflineException with the '
      'slow-connection sentence once the deadline passes, instead of hanging',
      () {
        FakeAsync().run((async) {
          // A client that accepts the request and then says nothing: the
          // captive-portal / stalled-cell case that no exception ever
          // surfaces on its own.
          final client = MockClient(
            (request) => Completer<http.Response>().future,
          );
          Object? caught;
          _serviceWith(client)
              .listOpenMeetups(viewerLat: 6.9, viewerLng: 79.8)
              .catchError((Object e) {
                caught = e;
                return const PagedResult<Meetup>(
                  items: [],
                  nextCursor: null,
                  hasMore: false,
                );
              });

          async.elapse(
            HttpMeetupService.requestTimeout - const Duration(seconds: 1),
          );
          expect(caught, isNull, reason: 'not yet at the deadline');

          async.elapse(const Duration(seconds: 2));
          expect(caught, isA<MeetupOfflineException>());
          expect(
            (caught! as MeetupOfflineException).message,
            contains('too slow'),
          );
        });
      },
    );
  });

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

  group('schedule conflict (409 with code schedule_conflict)', () {
    Map<String, Object?> conflictBody({Object? conflict}) => {
      'error': 'You are already hosting a meetup at that time.',
      'code': 'schedule_conflict',
      'conflict': conflict,
    };

    test('carries the meetup in the way as a typed exception', () async {
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode(
            conflictBody(
              conflict: {
                'id': 'busy-1',
                'host_user_id': 'me',
                'intent': 'coffee',
                'window_start_unix_seconds': 1757000000,
                'window_end_unix_seconds': 1757003600,
                'location_label': 'Cafe',
                'capacity': 2,
                'status': 'open',
                'created_at_unix_seconds': 1756990000,
                'is_hosted_by_me': true,
              },
            ),
          ),
          409,
        ),
      );

      await expectLater(
        _serviceWith(client).requestToJoin('meetup-2'),
        throwsA(
          isA<MeetupScheduleConflictException>()
              .having((e) => e.conflict.id, 'conflict.id', 'busy-1')
              .having((e) => e.conflict.isHostedByMe, 'hosted', isTrue)
              .having(
                (e) => e.message,
                'message',
                'You are already hosting a meetup at that time.',
              ),
        ),
      );
    });

    test('a plain 409 stays a plain MeetupConflictException', () async {
      final client = MockClient(
        (request) async =>
            http.Response(jsonEncode({'error': 'Meetup is not open.'}), 409),
      );

      await expectLater(
        _serviceWith(client).requestToJoin('meetup-2'),
        throwsA(
          isA<MeetupConflictException>().having(
            (e) => e is MeetupScheduleConflictException,
            'is schedule conflict',
            isFalse,
          ),
        ),
      );
    });

    test('a malformed conflict falls back to the plain 409 with its '
        'sentence intact', () async {
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode(conflictBody(conflict: {'id': 'busy-1'})),
          409,
        ),
      );

      await expectLater(
        _serviceWith(client).requestToJoin('meetup-2'),
        throwsA(
          isA<MeetupConflictException>()
              .having(
                (e) => e is MeetupScheduleConflictException,
                'is schedule conflict',
                isFalse,
              )
              .having(
                (e) => e.message,
                'message',
                'You are already hosting a meetup at that time.',
              ),
        ),
      );
    });
  });
}
