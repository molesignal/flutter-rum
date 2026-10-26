import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';

import 'support/configuration.dart';
import 'support/contract.dart';

/// The SDK against a real HTTP server on the loopback interface, through the
/// default transport: the bytes, headers, compression and answers are the ones
/// a MoleSignal receiver sees and sends.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Receiver receiver;

  setUp(() async {
    // The test binding answers every HTTP request with an error by default.
    HttpOverrides.global = null;
    receiver = await _Receiver.start();
    addTearDown(receiver.close);
  });

  Future<MoleSignalRumClient> startClient({
    bool compress = true,
    RumDiagnosticHandler? onError,
  }) async {
    final MoleSignalRumClient client = await MoleSignalRumClient.create(
      RumConfiguration(
        applicationId: 'e2e-mobile',
        clientToken: testClientToken,
        site: 'http://127.0.0.1:${receiver.port}',
        service: 'e2e-app',
        env: 'test',
        version: '1.0.0+1',
        platform: 'android',
        architecture: 'arm64',
        debugId: 'e2e-build',
        trackUserInteractions: true,
        trackFlutterErrors: false,
        trackPlatformErrors: false,
        trackAppLifecycle: false,
        trackLongTasks: false,
        trackViewPerformance: false,
        trackDeviceInfo: false,
        trackAnonymousUser: false,
        compressRequests: compress,
        flushInterval: const Duration(minutes: 1),
        retryInitialDelay: const Duration(minutes: 1),
        retryMaxDelay: const Duration(minutes: 1),
        persistence: MemoryRumPersistence(),
        onError: onError,
      ),
    );
    addTearDown(client.stop);
    return client;
  }

  test(
    'a session reaches the receiver as valid, compressed events',
    () async {
      final MoleSignalRumClient client = await startClient();

      client.startView('/checkout', name: 'Checkout');
      for (int index = 0; index < 8; index += 1) {
        client.addAction(
          'Action $index',
          context: <String, Object?>{'padding': 'x' * 200},
        );
      }
      client.addError(StateError('boom'));
      client.addDurationVital('sync', const Duration(milliseconds: 40));
      final RumFlushResult result = await client.flush();

      expect(result.dropped, 0);
      expect(result.remaining, 0);
      expect(receiver.requests, hasLength(1));
      final _Request request = receiver.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/api/v1/rum/events');
      expect(request.headers['authorization'], 'Bearer $testClientToken');
      expect(request.headers['content-type'], startsWith('application/json'));
      expect(request.headers['content-encoding'], 'gzip');
      expect(request.rawLength, lessThan(request.body.length));
      final List<dynamic> events = jsonDecode(request.body) as List<dynamic>;
      expect(
        events.map((dynamic e) => (e as Map<String, dynamic>)['type']).toSet(),
        <String>{'view', 'action', 'error', 'vital'},
      );
      for (final dynamic event in events) {
        expect(contractIssues(event), isEmpty, reason: jsonEncode(event));
      }
    },
    skip: contractSkipReason,
  );

  test(
    'small batches and compressRequests: false are sent as plain JSON',
    () async {
      final MoleSignalRumClient client = await startClient(compress: false);

      client.startView('/a');
      client.addAction(
        'Big',
        context: <String, Object?>{'padding': 'x' * 3000},
      );
      await client.flush();

      expect(receiver.requests.single.headers['content-encoding'], isNull);
      expect(jsonDecode(receiver.requests.single.body), isA<List<dynamic>>());
    },
  );

  test('events the receiver rejects are reported and not retried', () async {
    final List<RumDiagnostic> diagnostics = <RumDiagnostic>[];
    final MoleSignalRumClient client = await startClient(
      onError: diagnostics.add,
    );
    receiver.respond = (_Request request, List<dynamic> events) {
      final int action = events.indexWhere(
        (dynamic e) => (e as Map<String, dynamic>)['type'] == 'action',
      );
      return _Answer(
        202,
        jsonEncode(<String, Object?>{
          'accepted': events.length - 1,
          'rejected': <Object?>[
            <String, Object?>{'index': action, 'reason': 'CONTRACT_ENUM'},
          ],
        }),
      );
    };

    client.startView('/a');
    client.addAction('Bad');
    final RumFlushResult first = await client.flush();
    final RumFlushResult second = await client.flush();

    expect(first.dropReasons['rejected'], 1);
    expect(first.accepted, 1);
    expect(second.accepted, 0);
    expect(receiver.requests, hasLength(1));
    expect(
      diagnostics.map((RumDiagnostic d) => d.message),
      contains('RUM action event rejected by the receiver: CONTRACT_ENUM'),
    );
  });

  test('a 429 with Retry-After holds the events back', () async {
    final MoleSignalRumClient client = await startClient();
    receiver.respond = (_Request request, List<dynamic> events) =>
        const _Answer(429, '{"error":"slow down"}', <String, String>{
          'retry-after': '60',
        });

    client.addAction('Throttled');
    final RumFlushResult first = await client.flush();
    receiver.respond = null;
    final RumFlushResult second = await client.flush();

    expect(first.retried, greaterThan(0));
    expect(second.remaining, greaterThan(0));
    expect(receiver.requests, hasLength(1), reason: 'it waited as asked');
  });

  test('a server error is retried once the receiver is back', () async {
    final MoleSignalRumClient client = await startClient();
    receiver.respond = (_Request request, List<dynamic> events) =>
        const _Answer(503, 'maintenance');

    client.addAction('Retried');
    final RumFlushResult first = await client.flush();
    receiver.respond = null;
    final RumFlushResult second = await client.flush();

    expect(first.retried, greaterThan(0));
    expect(second.accepted, greaterThan(0));
    expect(second.remaining, 0);
    expect(receiver.requests, hasLength(2));
    expect(receiver.requests[0].body, receiver.requests[1].body);
  });

  test('an unreachable receiver keeps the events for later', () async {
    final MoleSignalRumClient client = await startClient();
    await receiver.close();

    client.addAction('Offline');
    final RumFlushResult result = await client.flush();

    expect(result.retried, greaterThan(0));
    expect(result.dropped, 0);
    expect(result.remaining, greaterThan(0));
  });
}

final class _Request {
  _Request(this.method, this.path, this.headers, this.body, this.rawLength);

  final String method;
  final String path;
  final Map<String, String> headers;

  /// The body after decompression.
  final String body;

  /// The number of bytes on the wire.
  final int rawLength;
}

final class _Answer {
  const _Answer(
    this.status,
    this.body, [
    this.headers = const <String, String>{},
  ]);

  final int status;
  final String body;
  final Map<String, String> headers;
}

final class _Receiver {
  _Receiver._(this._server) {
    _server.listen(_handle);
  }

  static Future<_Receiver> start() async =>
      _Receiver._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final List<_Request> requests = <_Request>[];

  /// Overrides the default answer: everything accepted.
  _Answer Function(_Request request, List<dynamic> events)? respond;

  int get port => _server.port;

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final List<int> raw = await request.fold<List<int>>(
      <int>[],
      (List<int> all, List<int> chunk) => all..addAll(chunk),
    );
    final bool gzipped = request.headers.value('content-encoding') == 'gzip';
    final String body = utf8.decode(gzipped ? gzip.decode(raw) : raw);
    final Map<String, String> headers = <String, String>{};
    request.headers.forEach((String name, List<String> values) {
      headers[name] = values.join(',');
    });
    final _Request seen = _Request(
      request.method,
      request.uri.path,
      headers,
      body,
      raw.length,
    );
    requests.add(seen);
    final List<dynamic> events = jsonDecode(body) as List<dynamic>;
    final _Answer answer =
        respond?.call(seen, events) ??
        _Answer(
          202,
          jsonEncode(<String, Object?>{
            'accepted': events.length,
            'rejected': <Object?>[],
          }),
        );
    request.response.statusCode = answer.status;
    answer.headers.forEach(request.response.headers.set);
    request.response.write(answer.body);
    await request.response.close();
  }
}
