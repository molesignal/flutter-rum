import 'dart:convert';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';

import 'support/configuration.dart';
import 'support/recording_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<MoleSignalRumClient> startClient(
    RecordingTransport transport, {
    MemoryRumPersistence? persistence,
    double sessionSampleRate = 100,
    RumDiagnosticHandler? onError,
  }) async {
    final MoleSignalRumClient client = await MoleSignalRumClient.create(
      testConfiguration(
        transport,
        persistence: persistence,
        sessionSampleRate: sessionSampleRate,
        onError: onError,
      ),
    );
    addTearDown(client.stop);
    return client;
  }

  group('requests that do not end', () {
    test('starting the same request key twice counts it once', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(transport);

      client.addAction('Load');
      client.startResource('k', 'GET', Uri.parse('https://api.example.test/a'));
      client.startResource('k', 'GET', Uri.parse('https://api.example.test/a'));
      client.stopResource('k', statusCode: 200);
      client.stopResource('k', statusCode: 200);
      await client.flush();

      expect(transport.eventsOf('resource'), hasLength(1));
      expect(
        at(transport.eventsOf('action').single, 'action.resource.count'),
        1,
      );
    });

    test('only the newest 256 unfinished requests are remembered', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(transport);

      for (int index = 0; index < 300; index += 1) {
        client.startResource(
          'r$index',
          'GET',
          Uri.parse('https://api.example.test/$index'),
        );
      }
      client.stopResource('r0', statusCode: 200);
      client.stopResource('r299', statusCode: 200);
      await client.flush();

      final List<Map<String, dynamic>> resources = transport.eventsOf(
        'resource',
      );
      expect(resources, hasLength(1));
      expect(
        at(resources.single, 'resource.url'),
        'https://api.example.test/299',
      );
    });

    test(
      'an action is not held open by a request that was forgotten',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(transport);

        client.addAction('Load');
        for (int index = 0; index < 257; index += 1) {
          client.startResource(
            'r$index',
            'GET',
            Uri.parse('https://api.example.test/$index'),
          );
        }
        // r0 was evicted; the action now waits only for the 256 that remain.
        for (int index = 1; index < 257; index += 1) {
          client.stopResource('r$index', statusCode: 200);
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
        // The action completed on its own: a later error is outside it.
        client.addError(StateError('later'));
        await client.flush();

        expect(at(transport.eventsOf('error').single, 'action'), isNull);
        expect(
          at(transport.eventsOf('action').single, 'action.resource.count'),
          256,
        );
      },
    );
  });

  group('crashes', () {
    test('are sent at once with the view that counts them', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(transport);

      client.startView('/checkout');
      client.recordCapturedError(StateError('fatal'), fatal: true);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(transport.eventsOf('error'), hasLength(1));
      expect(at(transport.latestViews.single, 'view.crash.count'), 1);
      expect(at(transport.latestViews.single, 'view.error.count'), 1);
    });
  });

  group('sampling', () {
    test(
      'a session renewed into an unsampled one closes the old view',
      () async {
        // A stored session keeps its own sampling decision; the next one is
        // decided by sessionSampleRate, here never.
        final MemoryRumPersistence persistence = MemoryRumPersistence(
          <String, String>{
            'molesignal_rum_session_checkout-mobile': jsonEncode(
              <String, Object?>{
                'version': 3,
                'current': <String, Object?>{
                  'id': 'stored-sampled-session',
                  'startedAtMicros': DateTime.now().microsecondsSinceEpoch,
                  'lastActivityMicros': DateTime.now().microsecondsSinceEpoch,
                  'sampled': true,
                  'replaySampled': false,
                },
              },
            ),
          },
        );
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(
          transport,
          persistence: persistence,
          sessionSampleRate: 0,
        );

        client.startView('/checkout');
        await client.flush();
        expect(at(transport.latestViews.single, 'view.is_active'), isTrue);
        expect(
          at(transport.latestViews.single, 'session.id'),
          'stored-sampled-session',
        );

        client.sessionManager.active().lastActivityMicros =
            DateTime.now().microsecondsSinceEpoch -
            const Duration(minutes: 20).inMicroseconds;
        client.addAction('Not recorded');
        await client.flush();

        expect(transport.latestViews, hasLength(1));
        expect(at(transport.latestViews.single, 'view.is_active'), isFalse);
        expect(transport.eventsOf('action'), isEmpty);
      },
    );

    test(
      'a session decided as unsampled stays silent for its whole life',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(
          transport,
          sessionSampleRate: 0,
        );

        client.startView('/a');
        client.addAction('x');
        client.recordCapturedError(StateError('x'), fatal: true);
        client.handleLifecycleState(AppLifecycleState.paused);
        client.handleLifecycleState(AppLifecycleState.resumed);
        await client.flush();
        await client.stop();

        expect(transport.requests, isEmpty);
      },
    );
  });
}
