import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';
import 'package:molesignal_flutter/src/transport/default_transport.dart';
import 'package:molesignal_flutter/src/transport/upload_response.dart';

import 'support/configuration.dart';
import 'support/recording_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<MoleSignalRumClient> startClient(
    RecordingTransport transport, {
    List<RumDiagnostic>? diagnostics,
    MemoryRumPersistence? persistence,
  }) async {
    final MoleSignalRumClient client = await MoleSignalRumClient.create(
      testConfiguration(
        transport,
        onError: diagnostics?.add,
        persistence: persistence,
        retryInitialDelay: const Duration(minutes: 1),
        retryMaxDelay: const Duration(minutes: 1),
      ),
    );
    addTearDown(client.stop);
    return client;
  }

  group('the receiver answer', () {
    test('rejected events are reported and are not sent again', () async {
      final List<RumDiagnostic> diagnostics = <RumDiagnostic>[];
      final RecordingTransport transport = RecordingTransport(
        respond: (RumTransportRequest request) {
          final List<Map<String, dynamic>> events = decodeEvents(request);
          final int bad = events.indexWhere(
            (Map<String, dynamic> e) => e['type'] == 'action',
          );
          return RumTransportResponse(
            ok: true,
            status: 202,
            body: jsonEncode(<String, Object?>{
              'accepted': events.length - 1,
              'rejected': <Object?>[
                <String, Object?>{
                  'index': bad,
                  'reason': 'CONTRACT_ENUM action.type',
                },
              ],
            }),
          );
        },
      );
      final MoleSignalRumClient client = await startClient(
        transport,
        diagnostics: diagnostics,
      );

      client.startView('/a');
      client.addAction('Rejected');
      final RumFlushResult first = await client.flush();
      final RumFlushResult second = await client.flush();

      expect(first.accepted, 1, reason: 'the view was accepted');
      expect(first.dropped, 1);
      expect(first.dropReasons['rejected'], 1);
      expect(first.retried, 0);
      expect(first.remaining, 0);
      expect(
        diagnostics.map((RumDiagnostic d) => d.message),
        contains(
          'RUM action event rejected by the receiver: CONTRACT_ENUM action.type',
        ),
      );
      expect(second.accepted, 0);
      expect(transport.eventRequests, hasLength(1), reason: 'no resend');
    });

    test('an answer without a body means every event was accepted', () async {
      final RecordingTransport transport = RecordingTransport(
        respond: (RumTransportRequest request) =>
            const RumTransportResponse(ok: true, status: 204),
      );
      final MoleSignalRumClient client = await startClient(transport);

      client.addAction('Plain');
      final RumFlushResult result = await client.flush();

      expect(result.accepted, greaterThan(0));
      expect(result.dropped, 0);
      expect(result.remaining, 0);
    });

    test('indexes the receiver invents are ignored', () async {
      final RecordingTransport transport = RecordingTransport(
        respond: (RumTransportRequest request) => RumTransportResponse(
          ok: true,
          status: 202,
          body: jsonEncode(<String, Object?>{
            'accepted': 1,
            'rejected': <Object?>[
              <String, Object?>{'index': 99, 'reason': 'nope'},
              <String, Object?>{'index': -1, 'reason': 'nope'},
            ],
          }),
        ),
      );
      final MoleSignalRumClient client = await startClient(transport);

      client.addAction('Plain');
      final RumFlushResult result = await client.flush();

      expect(result.dropped, 0);
    });

    test(
      'responses that cannot be retried are dropped and explained',
      () async {
        for (final int status in <int>[400, 401, 403, 404, 413, 422]) {
          final List<RumDiagnostic> diagnostics = <RumDiagnostic>[];
          final RecordingTransport transport = RecordingTransport(
            respond: (RumTransportRequest request) => RumTransportResponse(
              ok: false,
              status: status,
              body: '{"error":"invalid token msrum_secret"}',
            ),
          );
          final MoleSignalRumClient client = await startClient(
            transport,
            diagnostics: diagnostics,
          );

          client.addAction('Dropped $status');
          final RumFlushResult result = await client.flush();

          expect(result.dropped, greaterThan(0), reason: '$status');
          expect(result.dropReasons['non_retryable'], greaterThan(0));
          expect(result.remaining, 0, reason: '$status');
          expect(
            diagnostics.map((RumDiagnostic d) => d.message),
            contains(
              startsWith('RUM events upload rejected with HTTP $status'),
            ),
          );
          await client.stop();
        }
      },
    );

    test(
      'network errors, timeouts, rate limits and server errors are retried',
      () async {
        for (final int status in <int>[0, 408, 429, 500, 502, 503]) {
          bool fail = true;
          final RecordingTransport transport = RecordingTransport(
            respond: (RumTransportRequest request) => fail
                ? RumTransportResponse(ok: false, status: status)
                : const RumTransportResponse(ok: true, status: 202),
          );
          final MoleSignalRumClient client = await startClient(transport);

          client.addAction('Retry $status');
          final RumFlushResult first = await client.flush();
          fail = false;
          final RumFlushResult second = await client.flush();

          expect(first.retried, greaterThan(0), reason: '$status');
          expect(first.dropped, 0, reason: '$status');
          expect(first.remaining, greaterThan(0), reason: '$status');
          expect(second.accepted, greaterThan(0), reason: '$status');
          expect(second.remaining, 0, reason: '$status');
          await client.stop();
        }
      },
    );

    test('an exception from the transport is retried', () async {
      int calls = 0;
      final RecordingTransport transport = RecordingTransport(
        respond: (RumTransportRequest request) {
          calls += 1;
          if (calls == 1) throw const SocketException('offline');
          return const RumTransportResponse(ok: true, status: 202);
        },
      );
      final MoleSignalRumClient client = await startClient(transport);

      client.addAction('Offline');
      final RumFlushResult first = await client.flush();
      final RumFlushResult second = await client.flush();

      expect(first.retried, greaterThan(0));
      expect(second.accepted, greaterThan(0));
    });
  });

  group('Retry-After', () {
    test('holds back the next upload even when it is forced', () async {
      int status = 429;
      final RecordingTransport transport = RecordingTransport(
        respond: (RumTransportRequest request) => status == 429
            ? const RumTransportResponse(
                ok: false,
                status: 429,
                headers: <String, String>{'retry-after': '120'},
              )
            : const RumTransportResponse(ok: true, status: 202),
      );
      final MoleSignalRumClient client = await startClient(transport);

      client.addAction('Throttled');
      final RumFlushResult first = await client.flush();
      expect(first.retried, greaterThan(0));
      expect(transport.eventRequests, hasLength(1));

      status = 202;
      final RumFlushResult second = await client.flush();
      expect(
        transport.eventRequests,
        hasLength(1),
        reason: 'the receiver asked for two minutes of silence',
      );
      expect(second.remaining, greaterThan(0));
    });

    test('a malformed value falls back to the normal backoff', () async {
      int status = 503;
      final RecordingTransport transport = RecordingTransport(
        respond: (RumTransportRequest request) => status == 503
            ? const RumTransportResponse(
                ok: false,
                status: 503,
                headers: <String, String>{'retry-after': 'soon'},
              )
            : const RumTransportResponse(ok: true, status: 202),
      );
      final MoleSignalRumClient client = await startClient(transport);

      client.addAction('Unavailable');
      await client.flush();
      status = 202;
      final RumFlushResult second = await client.flush();

      expect(second.accepted, greaterThan(0));
    });

    test('is read as seconds or as an HTTP date', () {
      final DateTime now = DateTime.utc(2026, 10, 21, 8, 0, 0);
      expect(parseRetryAfter('120', now), const Duration(seconds: 120));
      expect(parseRetryAfter(' 0 ', now), Duration.zero);
      expect(
        parseRetryAfter('Wed, 21 Oct 2026 08:01:30 GMT', now),
        const Duration(seconds: 90),
      );
      expect(
        parseRetryAfter('Wed, 21 Oct 2026 07:00:00 GMT', now),
        Duration.zero,
        reason: 'a date in the past means now',
      );
      expect(
        parseRetryAfter('999999', now),
        maximumRetryAfter,
        reason: 'one hour at most',
      );
      expect(parseRetryAfter('-5', now), isNull);
      expect(parseRetryAfter('soon', now), isNull);
      expect(parseRetryAfter('', now), isNull);
      expect(parseRetryAfter(null, now), isNull);
    });
  });

  group('upload answer', () {
    test('parses accepted and rejected', () {
      final UploadAnswer answer = parseUploadAnswer(
        '{"accepted":2,"rejected":[{"index":1,"reason":"CONTRACT_REQUIRED"},'
        '{"index":4},{"reason":"no index"},"junk"]}',
      );
      expect(answer.accepted, 2);
      expect(answer.rejected.map((RejectedEvent r) => r.index), <int>[1, 4]);
      expect(answer.rejected.first.reason, 'CONTRACT_REQUIRED');
      expect(answer.rejected.last.reason, isEmpty);
    });

    test('tolerates anything else', () {
      for (final String? body in <String?>[
        null,
        '',
        '  ',
        'not json',
        '[]',
        '"text"',
        '{"accepted":"many","rejected":"none"}',
      ]) {
        final UploadAnswer answer = parseUploadAnswer(body);
        expect(answer.accepted, isNull, reason: '$body');
        expect(answer.rejected, isEmpty, reason: '$body');
      }
    });
  });

  group('the queue', () {
    test('keeps only the latest revision of a view while offline', () async {
      final MemoryRumPersistence persistence = MemoryRumPersistence();
      final RecordingTransport offline = RecordingTransport(
        respond: (RumTransportRequest request) =>
            const RumTransportResponse(ok: false, status: 503),
      );
      final MoleSignalRumClient client = await startClient(
        offline,
        persistence: persistence,
      );

      client.startView('/a');
      for (int index = 0; index < 5; index += 1) {
        client.addAction('Action $index');
        await client.flush();
      }
      final String key = persistence.values.keys.singleWhere(
        (String key) => key.contains('_queue_'),
      );
      final Map<String, dynamic> state =
          jsonDecode(persistence.values[key]!) as Map<String, dynamic>;
      final List<dynamic> queued = state['events'] as List<dynamic>;
      final List<dynamic> views = queued
          .map((dynamic item) => (item as Map<String, dynamic>)['event'])
          .where(
            (dynamic event) =>
                (event as Map<String, dynamic>)['type'] == 'view',
          )
          .toList();
      expect(views, hasLength(1));
      expect(at(views.single as Map<String, dynamic>, 'view.revision'), 6);
      expect(queued, hasLength(6), reason: 'five actions and one view');
    });

    test(
      'drops a queue written by an older SDK instead of sending it',
      () async {
        final MemoryRumPersistence persistence = MemoryRumPersistence();
        final int now = DateTime.now().microsecondsSinceEpoch;
        await persistence.write(
          'molesignal_rum_queue_checkout-mobile',
          jsonEncode(<String, Object?>{
            'version': 1,
            'events': <Object?>[
              <String, Object?>{
                'kind': 'action',
                'event': <String, Object?>{'type': 'tap', 'name': 'legacy'},
                'bytes': 40,
                'created_at_micros': now,
                'attempts': 0,
                'next_attempt_micros': 0,
              },
            ],
          }),
        );
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(
          transport,
          persistence: persistence,
        );

        final RumFlushResult result = await client.flush();

        expect(transport.requests, isEmpty);
        expect(result.remaining, 0);
      },
    );

    test('refuses an event that is too large for one request', () async {
      final List<RumDiagnostic> diagnostics = <RumDiagnostic>[];
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await MoleSignalRumClient.create(
        testConfiguration(
          transport,
          onError: diagnostics.add,
          beforeSend: (RumContext event, RumBeforeSendContext context) {
            if (context.kind == RumEventKind.action) {
              event['context'] = <String, Object?>{
                for (int key = 0; key < 4; key += 1)
                  'k$key': List<String>.filled(100, 'x' * 4000),
              };
            }
            return true;
          },
        ),
      );
      addTearDown(client.stop);

      client.addAction('Huge');
      final RumFlushResult result = await client.flush();

      expect(transport.eventsOf('action'), isEmpty);
      expect(result.dropReasons['event_too_large'], 1);
    });
  });

  group('the default transport', () {
    Future<(RumTransportResponse, http.Request)> post(
      RumTransportRequest request, {
      http.Response? response,
    }) async {
      late http.Request seen;
      final DefaultRumTransport transport = DefaultRumTransport(
        client: MockClient((http.Request incoming) async {
          seen = incoming;
          return response ?? http.Response('{"accepted":1}', 202);
        }),
      );
      final RumTransportResponse result = await transport.send(request);
      await transport.close();
      return (result, seen);
    }

    RumTransportRequest requestOf(String body, {required bool compress}) =>
        RumTransportRequest(
          url: Uri.parse('https://rum.example.test/api/v1/rum/events'),
          body: body,
          headers: const <String, String>{
            'authorization': 'Bearer secret',
            'content-type': 'application/json',
          },
          kind: RumUploadKind.events,
          compress: compress,
        );

    test('compresses large bodies when asked to', () async {
      final String body = jsonEncode(<String, Object?>{
        'events': List<String>.filled(200, 'repeating event payload'),
      });
      final (RumTransportResponse response, http.Request seen) = await post(
        requestOf(body, compress: true),
      );

      expect(seen.headers['content-encoding'], 'gzip');
      expect(seen.headers['authorization'], 'Bearer secret');
      expect(seen.headers['content-type'], startsWith('application/json'));
      expect(seen.bodyBytes.length, lessThan(body.length));
      expect(utf8.decode(gzip.decode(seen.bodyBytes)), body);
      expect(response.ok, isTrue);
      expect(response.status, 202);
      expect(response.body, '{"accepted":1}');
    });

    test('leaves small bodies and uncompressed requests alone', () async {
      final (RumTransportResponse _, http.Request small) = await post(
        requestOf('[{"type":"view"}]', compress: true),
      );
      expect(small.headers.containsKey('content-encoding'), isFalse);
      expect(small.body, '[{"type":"view"}]');

      final String large = jsonEncode(List<String>.filled(500, 'payload'));
      final (RumTransportResponse _, http.Request plain) = await post(
        requestOf(large, compress: false),
      );
      expect(plain.headers.containsKey('content-encoding'), isFalse);
      expect(plain.body, large);
    });

    test(
      'hands back the status, the body and the lower-case headers',
      () async {
        final (RumTransportResponse response, http.Request _) = await post(
          requestOf('[]', compress: false),
          response: http.Response(
            'slow down',
            429,
            headers: <String, String>{'Retry-After': '30'},
          ),
        );

        expect(response.ok, isFalse);
        expect(response.status, 429);
        expect(response.body, 'slow down');
        expect(response.headers['retry-after'], '30');
      },
    );
  });
}
