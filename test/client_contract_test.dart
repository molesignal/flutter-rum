import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';

import 'support/configuration.dart';
import 'support/recording_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('validates required configuration', () async {
    await expectLater(
      initRum(
        RumConfiguration(
          applicationId: '',
          clientToken: 'invalid',
          site: 'https://rum.example.test',
          persistence: MemoryRumPersistence(),
        ),
      ),
      throwsArgumentError,
    );
    await expectLater(
      initRum(
        RumConfiguration(
          applicationId: 'app',
          clientToken: testClientToken,
          site: 'ftp://rum.example.test',
          persistence: MemoryRumPersistence(),
        ),
      ),
      throwsArgumentError,
    );
  });

  test('initRum installs the client that getRum returns', () async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient first = await initRum(
      testConfiguration(transport),
    );
    expect(getRum(), same(first));
    final MoleSignalRumClient second = await initRum(
      testConfiguration(RecordingTransport()),
    );
    expect(getRum(), same(second));
    expect(identical(first, second), isFalse);
    await second.stop();
  });

  group('upload address', () {
    Future<Uri> endpointFor(String site) async {
      // The address is what is under test, so the default path check is off.
      final RecordingTransport transport = RecordingTransport(validate: false);
      final MoleSignalRumClient client = await MoleSignalRumClient.create(
        testConfiguration(transport, site: site),
      );
      client.addAction('Ping');
      await client.stop();
      return transport.eventRequests.first.url;
    }

    test('is completed from whatever prefix the site carries', () async {
      for (final MapEntry<String, String> entry in <String, String>{
        'https://rum.example.test':
            'https://rum.example.test/api/v1/rum/events',
        'https://rum.example.test/':
            'https://rum.example.test/api/v1/rum/events',
        'https://rum.example.test/api':
            'https://rum.example.test/api/v1/rum/events',
        'https://rum.example.test/api/v1':
            'https://rum.example.test/api/v1/rum/events',
        'https://rum.example.test/api/v1/rum':
            'https://rum.example.test/api/v1/rum/events',
        'https://rum.example.test/proxy':
            'https://rum.example.test/proxy/api/v1/rum/events',
        'http://localhost:8080': 'http://localhost:8080/api/v1/rum/events',
      }.entries) {
        expect(
          await endpointFor(entry.key),
          Uri.parse(entry.value),
          reason: entry.key,
        );
      }
    });
  });

  test('beforeSend can mutate and drop events of any type', () async {
    final RecordingTransport transport = RecordingTransport();
    final List<RumEventKind> seen = <RumEventKind>[];
    final MoleSignalRumClient client = await MoleSignalRumClient.create(
      testConfiguration(
        transport,
        beforeSend: (RumContext event, RumBeforeSendContext context) {
          seen.add(context.kind);
          expect(event['type'], context.kind.wireName);
          if (context.kind == RumEventKind.action &&
              (event['action']! as Map<String, Object?>)['target'] is Map &&
              ((event['action']! as Map<String, Object?>)['target']!
                      as Map<String, Object?>)['name'] ==
                  'Drop me') {
            return false;
          }
          event['context'] = <String, Object?>{'processed': true};
          return true;
        },
      ),
    );
    addTearDown(client.stop);

    client.addAction('Keep me');
    client.addAction('Drop me');
    await client.flush();

    final List<Map<String, dynamic>> actions = transport.eventsOf('action');
    expect(
      actions.map((Map<String, dynamic> e) => at(e, 'action.target.name')),
      <Object?>['Keep me'],
    );
    expect(at(actions.single, 'context.processed'), isTrue);
    expect(
      seen,
      containsAll(<RumEventKind>[RumEventKind.view, RumEventKind.action]),
    );
  });

  test('a throwing beforeSend never loses the event or the app', () async {
    final RecordingTransport transport = RecordingTransport();
    final List<RumDiagnostic> diagnostics = <RumDiagnostic>[];
    final MoleSignalRumClient client = await MoleSignalRumClient.create(
      testConfiguration(
        transport,
        onError: diagnostics.add,
        beforeSend: (RumContext event, RumBeforeSendContext context) =>
            throw StateError('callback bug'),
      ),
    );
    addTearDown(client.stop);

    client.addAction('Still sent');
    await client.flush();

    expect(transport.eventsOf('action'), hasLength(1));
    expect(
      diagnostics.map((RumDiagnostic d) => d.message),
      contains('RUM beforeSend failed'),
    );
  });

  test('retryable failures preserve queued payloads', () async {
    int attempts = 0;
    final RecordingTransport transport = RecordingTransport(
      respond: (RumTransportRequest request) {
        attempts += 1;
        return attempts == 1
            ? const RumTransportResponse(ok: false, status: 503)
            : const RumTransportResponse(ok: true, status: 202);
      },
    );
    final MoleSignalRumClient client = await MoleSignalRumClient.create(
      testConfiguration(transport),
    );
    addTearDown(client.stop);

    client.addAction('Retry me');
    await client.flush();
    await client.flush();

    expect(transport.eventRequests, hasLength(2));
    expect(
      jsonDecode(transport.eventRequests[0].body),
      jsonDecode(transport.eventRequests[1].body),
    );
  });

  test('zero sampling emits no events', () async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient client = await MoleSignalRumClient.create(
      testConfiguration(transport, sessionSampleRate: 0),
    );
    addTearDown(client.stop);

    client.startView('/', name: 'Home');
    client.addAction('Ignored');
    client.addError(StateError('Ignored'));
    client.startResource('r', 'GET', Uri.parse('https://api.example.test/'));
    client.stopResource('r', statusCode: 200);
    client.addDurationVital('v', const Duration(seconds: 1));
    await client.flush();

    expect(transport.requests, isEmpty);
    expect(client.getInternalContext().sessionId, isNull);
  });

  test('stop reports the active view one last time as inactive', () async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient client = await MoleSignalRumClient.create(
      testConfiguration(transport),
    );

    client.startView('/checkout');
    client.addAction('Pay');
    await client.stop();

    final Map<String, dynamic> view = transport.latestViews.single;
    expect(at(view, 'view.is_active'), isFalse);
    expect(at(view, 'view.action.count'), 1);
    expect(transport.eventsOf('action'), hasLength(1));
    // Stopping twice is harmless.
    expect(await client.stop(), isA<RumFlushResult>());
    client.addAction('After stop');
    expect(transport.eventsOf('action'), hasLength(1));
  });
}
