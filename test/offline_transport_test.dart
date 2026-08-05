import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';

const String _clientToken =
    'msrum_aB3kZ1xT9pQrU7nM_dFgHjKl8eRvNcWxYz4tBmEqPaS2vG6Qz';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('offline events survive stop and restart, then drain exactly', () async {
    final MemoryRumPersistence persistence = MemoryRumPersistence();
    final _FailingTransport failing = _FailingTransport(status: 503);
    final MoleSignalRumClient first = await MoleSignalRumClient.create(
      _configuration(failing, persistence),
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

    final _RecordingTransport recovered = _RecordingTransport();
    final MoleSignalRumClient second = await MoleSignalRumClient.create(
      _configuration(recovered, persistence),
    );
    final RumFlushResult recoveredFlush = await second.flush();
    expect(recoveredFlush.remaining, 0);
    expect(
      recovered
          .events(RumEventKind.action)
          .any(
            (Map<String, dynamic> event) =>
                event['name'] == 'Persist across restart',
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
      final _RetryOnceTransport transport = _RetryOnceTransport();
      final MoleSignalRumClient client = await MoleSignalRumClient.create(
        _configuration(transport, MemoryRumPersistence()),
      );
      client.addAction('Retry with identity');
      final RumFlushResult first = await client.flush();
      final RumFlushResult second = await client.flush();
      expect(first.retried, greaterThanOrEqualTo(1));
      expect(second.accepted, greaterThanOrEqualTo(1));
      final List<RumTransportRequest> attempts = transport.requests
          .where(
            (RumTransportRequest request) =>
                request.kind == RumEventKind.action,
          )
          .toList(growable: false);
      expect(attempts, hasLength(2));
      expect(jsonDecode(attempts[0].body), jsonDecode(attempts[1].body));
      await client.stop();
    },
  );

  test(
    'queue limits and non-retryable responses expose drop reasons',
    () async {
      final List<RumDiagnostic> diagnostics = <RumDiagnostic>[];
      final _FailingTransport unavailable = _FailingTransport(status: 503);
      final MoleSignalRumClient bounded = await MoleSignalRumClient.create(
        _configuration(
          unavailable,
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
        final _FailingTransport rejectedTransport = _FailingTransport(
          status: status,
        );
        final MoleSignalRumClient rejected = await MoleSignalRumClient.create(
          _configuration(rejectedTransport, MemoryRumPersistence()),
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
        _configuration(_FailingTransport(status: 503), persistence),
      );
      first.addAction('expire me');
      await first.flush();
      await first.stop();

      final String queueKey = persistence.values.keys.singleWhere(
        (String key) => key.contains('_queue_'),
      );
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
          _RecordingTransport(),
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
    final MoleSignalRumClient client = await MoleSignalRumClient.create(
      _configuration(
        _HangingTransport(),
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

RumConfiguration _configuration(
  RumTransport transport,
  MemoryRumPersistence persistence, {
  int maxQueueSize = 1000,
  Duration queueItemTtl = const Duration(hours: 24),
  Duration requestTimeout = const Duration(seconds: 15),
  Duration flushTimeout = const Duration(seconds: 20),
  RumDiagnosticHandler? onError,
}) => RumConfiguration(
  applicationId: 'offline-mobile',
  clientToken: _clientToken,
  site: 'https://rum.example.test',
  service: 'offline-app',
  version: '2.0.0+8',
  platform: 'android',
  architecture: 'arm64',
  debugId: 'offline-build-8',
  trackFlutterErrors: false,
  trackPlatformErrors: false,
  trackAppLifecycle: false,
  trackLongTasks: false,
  trackViewPerformance: false,
  trackAnonymousUser: false,
  flushInterval: const Duration(minutes: 1),
  replayFlushInterval: const Duration(minutes: 1),
  batchSize: 100,
  maxQueueSize: maxQueueSize,
  queueItemTtl: queueItemTtl,
  requestTimeout: requestTimeout,
  flushTimeout: flushTimeout,
  retryInitialDelay: const Duration(minutes: 1),
  retryMaxDelay: const Duration(minutes: 1),
  transport: transport,
  persistence: persistence,
  onError: onError,
);

List<Map<String, dynamic>> _events(RumTransportRequest request) =>
    (jsonDecode(request.body) as List<dynamic>)
        .map(
          (dynamic value) =>
              Map<String, dynamic>.from(value as Map<dynamic, dynamic>),
        )
        .toList(growable: false);

final class _RecordingTransport extends RumTransport {
  final List<RumTransportRequest> requests = <RumTransportRequest>[];

  @override
  Future<RumTransportResponse> send(RumTransportRequest request) async {
    requests.add(request);
    return const RumTransportResponse(ok: true, status: 200);
  }

  List<Map<String, dynamic>> events(RumEventKind kind) => requests
      .where((RumTransportRequest request) => request.kind == kind)
      .expand(_events)
      .toList(growable: false);
}

final class _FailingTransport extends RumTransport {
  _FailingTransport({required this.status});

  final int status;

  @override
  Future<RumTransportResponse> send(RumTransportRequest request) async =>
      RumTransportResponse(ok: false, status: status);
}

final class _RetryOnceTransport extends _RecordingTransport {
  bool _failedAction = false;

  @override
  Future<RumTransportResponse> send(RumTransportRequest request) async {
    requests.add(request);
    if (request.kind == RumEventKind.action && !_failedAction) {
      _failedAction = true;
      return const RumTransportResponse(ok: false, status: 503);
    }
    return const RumTransportResponse(ok: true, status: 200);
  }
}

final class _HangingTransport extends RumTransport {
  @override
  Future<RumTransportResponse> send(RumTransportRequest request) =>
      Completer<RumTransportResponse>().future;
}
