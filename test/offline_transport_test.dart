import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';

import 'support/configuration.dart';
import 'support/recording_transport.dart';

RecordingTransport _failing(int status) => RecordingTransport(
  respond: (RumTransportRequest request) =>
      RumTransportResponse(ok: false, status: status),
);

RumConfiguration _configuration(
  RumTransport transport,
  MemoryRumPersistence persistence, {
  int maxQueueSize = 1000,
  Duration queueItemTtl = const Duration(hours: 24),
  Duration requestTimeout = const Duration(seconds: 15),
  Duration flushTimeout = const Duration(seconds: 20),
  RumDiagnosticHandler? onError,
}) => testConfiguration(
  transport,
  applicationId: 'offline-mobile',
  batchSize: 100,
  maxQueueSize: maxQueueSize,
  queueItemTtl: queueItemTtl,
  requestTimeout: requestTimeout,
  flushTimeout: flushTimeout,
  retryInitialDelay: const Duration(minutes: 1),
  retryMaxDelay: const Duration(minutes: 1),
  persistence: persistence,
  onError: onError,
);

String _queueKey(MemoryRumPersistence persistence) => persistence.values.keys
    .singleWhere((String key) => key.contains('_queue_'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('offline events survive stop and restart, then drain exactly', () async {
    final MemoryRumPersistence persistence = MemoryRumPersistence();
    final MoleSignalRumClient first = await MoleSignalRumClient.create(
      _configuration(_failing(503), persistence),
    );
    first.addAction('Persist across restart');
    final RumFlushResult firstFlush = await first.flush();
    expect(firstFlush.retried, greaterThanOrEqualTo(1));
    expect(firstFlush.remaining, greaterThanOrEqualTo(1));
    expect(
      persistence.values.keys.any((String key) => key.contains('_queue_')),
      isTrue,
    );
    await first.stop();

    final RecordingTransport recovered = RecordingTransport();
    final MoleSignalRumClient second = await MoleSignalRumClient.create(
      _configuration(recovered, persistence),
    );
    final RumFlushResult recoveredFlush = await second.flush();
    expect(recoveredFlush.remaining, 0);
    expect(
      recovered
          .eventsOf('action')
          .any(
            (Map<String, dynamic> event) =>
                at(event, 'action.target.name') == 'Persist across restart',
          ),
      isTrue,
    );
    expect(
      persistence.values.keys.any((String key) => key.contains('_queue_')),
      isFalse,
    );
    await second.stop();
  });

  test(
    'retry preserves payload while flush reports accepted and retried',
    () async {
      int calls = 0;
      final RecordingTransport transport = RecordingTransport(
        respond: (RumTransportRequest request) {
          calls += 1;
          return calls == 1
              ? const RumTransportResponse(ok: false, status: 503)
              : const RumTransportResponse(ok: true, status: 202);
        },
      );
      final MoleSignalRumClient client = await MoleSignalRumClient.create(
        _configuration(transport, MemoryRumPersistence()),
      );
      client.addAction('Retry with identity');
      final RumFlushResult first = await client.flush();
      final RumFlushResult second = await client.flush();
      expect(first.retried, greaterThanOrEqualTo(1));
      expect(second.accepted, greaterThanOrEqualTo(1));
      expect(transport.eventRequests, hasLength(2));
      expect(
        jsonDecode(transport.eventRequests[0].body),
        jsonDecode(transport.eventRequests[1].body),
      );
      await client.stop();
    },
  );

  test(
    'queue limits and non-retryable responses expose drop reasons',
    () async {
      final List<RumDiagnostic> diagnostics = <RumDiagnostic>[];
      final MoleSignalRumClient bounded = await MoleSignalRumClient.create(
        _configuration(
          _failing(503),
          MemoryRumPersistence(),
          maxQueueSize: 20,
          onError: diagnostics.add,
        ),
      );
      for (int index = 0; index < 30; index += 1) {
        bounded.addAction('queued-$index');
      }
      final RumFlushResult boundedResult = await bounded.flush();
      expect(boundedResult.dropped, greaterThan(0));
      expect(boundedResult.dropReasons['queue_full'], greaterThan(0));
      expect(boundedResult.remaining, lessThanOrEqualTo(20));
      expect(
        diagnostics.any(
          (RumDiagnostic diagnostic) =>
              diagnostic.message == 'RUM event dropped: queue_full',
        ),
        isTrue,
      );
      await bounded.stop();

      for (final int status in <int>[401, 403]) {
        final MoleSignalRumClient rejected = await MoleSignalRumClient.create(
          _configuration(_failing(status), MemoryRumPersistence()),
        );
        rejected.addAction(
          status == 401 ? 'revoked token' : 'wrong application',
        );
        final RumFlushResult rejectedResult = await rejected.flush();
        expect(rejectedResult.dropped, greaterThanOrEqualTo(1));
        expect(
          rejectedResult.dropReasons['non_retryable'],
          greaterThanOrEqualTo(1),
        );
        expect(rejectedResult.remaining, 0);
        await rejected.stop();
      }
    },
  );

  test(
    'expired persisted events are dropped during restart recovery',
    () async {
      final MemoryRumPersistence persistence = MemoryRumPersistence();
      final MoleSignalRumClient first = await MoleSignalRumClient.create(
        _configuration(_failing(503), persistence),
      );
      first.addAction('expire me');
      await first.flush();
      await first.stop();

      final String queueKey = _queueKey(persistence);
      final Map<String, dynamic> state = Map<String, dynamic>.from(
        jsonDecode(persistence.values[queueKey]!) as Map<dynamic, dynamic>,
      );
      for (final String key in <String>[
        'events',
        'replay_events',
        'replay_segments',
      ]) {
        for (final dynamic raw
            in (state[key] as List<dynamic>? ?? <dynamic>[])) {
          (raw as Map<String, dynamic>)['created_at_micros'] = 1;
        }
      }
      await persistence.write(queueKey, jsonEncode(state));

      final MoleSignalRumClient recovered = await MoleSignalRumClient.create(
        _configuration(
          RecordingTransport(),
          persistence,
          queueItemTtl: const Duration(minutes: 1),
        ),
      );
      final RumFlushResult result = await recovered.flush();
      expect(result.dropReasons['expired'], greaterThanOrEqualTo(1));
      expect(result.remaining, 0);
      await recovered.stop();
    },
  );

  test('flush and stop complete within configured bounds', () async {
    final RecordingTransport hanging = RecordingTransport(
      respond: (RumTransportRequest request) =>
          Completer<RumTransportResponse>().future,
    );
    final MoleSignalRumClient client = await MoleSignalRumClient.create(
      _configuration(
        hanging,
        MemoryRumPersistence(),
        requestTimeout: const Duration(seconds: 1),
        flushTimeout: const Duration(seconds: 1),
      ),
    );
    client.addAction('bounded flush');
    final Stopwatch elapsed = Stopwatch()..start();
    final RumFlushResult result = await client.flush();
    elapsed.stop();
    expect(result.timedOut, isTrue);
    expect(result.remaining, greaterThan(0));
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 2)));
    final RumFlushResult stopped = await client.stop();
    expect(stopped.timedOut, isTrue);
  });
}
