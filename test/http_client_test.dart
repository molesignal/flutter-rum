import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';

import 'support/configuration.dart';
import 'support/recording_transport.dart';

const String _traceId = '4bf92f3577b34da6a3ce929d0e0e4736';
const String _spanId = '00f067aa0ba902b7';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<MoleSignalRumClient> startClient(
    RecordingTransport transport, {
    String site = 'https://rum.example.test',
    List<Pattern> excludedUrls = const <Pattern>[],
    List<Pattern> allowedTracingUrls = const <Pattern>[],
    bool trackUserInteractions = false,
  }) async {
    final MoleSignalRumClient client = await MoleSignalRumClient.create(
      testConfiguration(
        transport,
        site: site,
        excludedUrls: excludedUrls,
        allowedTracingUrls: allowedTracingUrls,
        trackUserInteractions: trackUserInteractions,
      ),
    );
    addTearDown(client.stop);
    return client;
  }

  test('HTTP wrapper records resources and W3C trace context', () async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient rum = await startClient(
      transport,
      site: 'https://rum.example.test/api/v1',
    );
    final MoleSignalHttpClient client = MoleSignalHttpClient(
      rum,
      inner: MockClient(
        (http.Request request) async => http.Response(
          'abc',
          200,
          headers: <String, String>{
            'traceparent': '00-$_traceId-$_spanId-01',
            'content-length': '3',
          },
        ),
      ),
    );

    await client.get(
      Uri.parse('https://api.example.test/orders?secret=value'),
      headers: const <String, String>{
        'traceparent': '00-$_traceId-1111111111111111-01',
      },
    );
    await rum.flush();

    final Map<String, dynamic> resource = transport.eventsOf('resource').single;
    expect(at(resource, 'resource.type'), 'native');
    expect(at(resource, 'resource.method'), 'GET');
    expect(at(resource, 'resource.url'), 'https://api.example.test/orders');
    expect(at(resource, 'resource.status_code'), 200);
    expect(at(resource, 'resource.size'), 3);
    expect(at(resource, 'resource.duration')! as int, greaterThanOrEqualTo(0));
    expect(at(resource, 'resource.trace_id'), _traceId);
    expect(at(resource, 'resource.span_id'), _spanId);
    client.close();
  });

  test(
    'a request traceparent, or Server-Timing, is used when the response has none',
    () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient rum = await startClient(transport);
      final MoleSignalHttpClient client = MoleSignalHttpClient(
        rum,
        inner: MockClient((http.Request request) async {
          if (request.url.path == '/timing') {
            return http.Response(
              '',
              200,
              headers: <String, String>{
                'server-timing':
                    'db;dur=3, traceparent;desc="00-$_traceId-$_spanId-01"',
              },
            );
          }
          return http.Response('', 200);
        }),
      );

      await client.get(
        Uri.parse('https://api.example.test/request'),
        headers: const <String, String>{
          'traceparent': '00-$_traceId-1111111111111111-01',
        },
      );
      await client.get(Uri.parse('https://api.example.test/timing'));
      await client.get(Uri.parse('https://api.example.test/none'));
      await rum.flush();

      final List<Map<String, dynamic>> resources = transport.eventsOf(
        'resource',
      );
      expect(at(resources[0], 'resource.span_id'), '1111111111111111');
      expect(at(resources[1], 'resource.span_id'), _spanId);
      expect(at(resources[2], 'resource.trace_id'), isNull);
      client.close();
    },
  );

  test('trace headers are only read from allowed URLs', () async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient rum = await startClient(
      transport,
      allowedTracingUrls: <Pattern>['api.example.test'],
    );
    final MoleSignalHttpClient client = MoleSignalHttpClient(
      rum,
      inner: MockClient(
        (http.Request request) async => http.Response(
          '',
          200,
          headers: <String, String>{'traceparent': '00-$_traceId-$_spanId-01'},
        ),
      ),
    );

    await client.get(Uri.parse('https://api.example.test/a'));
    await client.get(Uri.parse('https://other.example.test/b'));
    await rum.flush();

    final List<Map<String, dynamic>> resources = transport.eventsOf('resource');
    expect(at(resources[0], 'resource.trace_id'), _traceId);
    expect(at(resources[1], 'resource.trace_id'), isNull);
    client.close();
  });

  test('SDK and excluded URLs are not recorded', () async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient rum = await startClient(
      transport,
      excludedUrls: <Pattern>['/health', RegExp(r'/private/')],
    );
    final MoleSignalHttpClient client = MoleSignalHttpClient(
      rum,
      inner: MockClient((http.Request request) async => http.Response('', 200)),
    );

    await client.get(Uri.parse('https://api.example.test/health'));
    await client.get(Uri.parse('https://api.example.test/private/profile'));
    await client.post(Uri.parse('https://rum.example.test/api/v1/rum/events'));
    await client.post(Uri.parse('https://rum.example.test/api/v1/rum/replay'));
    await rum.flush();

    expect(transport.eventsOf('resource'), isEmpty);
    client.close();
  });

  test('resource duration ends only after response body completion', () async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient rum = await startClient(transport);
    final MoleSignalHttpClient client = MoleSignalHttpClient(
      rum,
      inner: _DelayedBodyClient(),
    );

    final Stopwatch elapsed = Stopwatch()..start();
    final http.StreamedResponse response = await client.send(
      http.Request('GET', Uri.parse('https://api.example.test/delayed')),
    );
    await rum.flush();
    expect(
      transport.eventsOf('resource'),
      isEmpty,
      reason: 'the body is still being read',
    );
    final List<int> bytes = await response.stream
        .expand((List<int> value) => value)
        .toList();
    elapsed.stop();
    await rum.flush();

    expect(bytes, <int>[1, 2, 3]);
    final Map<String, dynamic> resource = transport.eventsOf('resource').single;
    final int duration = at(resource, 'resource.duration')! as int;
    expect(duration, greaterThanOrEqualTo(20000000));
    expect(
      duration,
      lessThanOrEqualTo(elapsed.elapsed.inMicroseconds * 1000 + 100000000),
    );
    expect(at(resource, 'resource.size'), 3);
    client.close();
  });

  test('transport failures become sanitized network errors', () async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient rum = await startClient(transport);
    final MoleSignalHttpClient client = MoleSignalHttpClient(
      rum,
      inner: _TimeoutClient(),
    );

    await expectLater(
      client.get(
        Uri.parse('https://user:password@api.example.test/orders?token=secret'),
      ),
      throwsA(isA<TimeoutException>()),
    );
    await rum.flush();

    final Map<String, dynamic> resource = transport.eventsOf('resource').single;
    expect(at(resource, 'resource.url'), 'https://api.example.test/orders');
    expect(at(resource, 'resource.status_code'), 0);
    final Map<String, dynamic> error = transport.eventsOf('error').single;
    expect(at(error, 'error.source'), 'network');
    expect(at(error, 'error.type'), 'timeout');
    final String wire = jsonEncode(<Object?>[resource, error]);
    expect(wire, isNot(contains(testClientToken)));
    expect(wire, isNot(contains('user:password')));
    expect(wire, isNot(contains('token=secret')));
    client.close();
  });

  test('an HTTP error status is a resource, not an error', () async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient rum = await startClient(transport);
    final MoleSignalHttpClient client = MoleSignalHttpClient(
      rum,
      inner: MockClient((http.Request request) async => http.Response('', 503)),
    );

    await client.get(Uri.parse('https://api.example.test/down'));
    await rum.flush();

    expect(
      at(transport.eventsOf('resource').single, 'resource.status_code'),
      503,
    );
    expect(transport.eventsOf('error'), isEmpty);
    client.close();
  });

  test(
    'a failing response body is an error on a resource that has a status',
    () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient rum = await startClient(transport);
      final MoleSignalHttpClient client = MoleSignalHttpClient(
        rum,
        inner: _BrokenBodyClient(),
      );

      final http.StreamedResponse response = await client.send(
        http.Request('GET', Uri.parse('https://api.example.test/broken')),
      );
      await expectLater(
        response.stream.drain<void>(),
        throwsA(isA<StateError>()),
      );
      await rum.flush();

      expect(
        at(transport.eventsOf('resource').single, 'resource.status_code'),
        200,
      );
      expect(at(transport.eventsOf('error').single, 'error.source'), 'network');
      client.close();
    },
  );

  test(
    'a response body nobody finishes reading is not reported as an error',
    () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient rum = await startClient(transport);
      final MoleSignalHttpClient client = MoleSignalHttpClient(
        rum,
        inner: _DelayedBodyClient(),
      );

      final http.StreamedResponse response = await client.send(
        http.Request('GET', Uri.parse('https://api.example.test/delayed')),
      );
      final StreamSubscription<List<int>> subscription = response.stream.listen(
        (List<int> _) {},
      );
      await subscription.cancel();
      await rum.flush();

      expect(transport.eventsOf('resource'), hasLength(1));
      expect(transport.eventsOf('error'), isEmpty);
      client.close();
    },
  );

  test('the request that a tap started belongs to the tap', () async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient rum = await startClient(
      transport,
      trackUserInteractions: true,
    );
    final MoleSignalHttpClient client = MoleSignalHttpClient(
      rum,
      inner: MockClient((http.Request request) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return http.Response('ok', 200);
      }),
    );

    rum.recordTap(name: 'Pay', position: const Offset(1, 1), explicit: true);
    await client.get(Uri.parse('https://api.example.test/pay'));
    await rum.flush();

    final Map<String, dynamic> action = transport.eventsOf('action').single;
    final Map<String, dynamic> resource = transport.eventsOf('resource').single;
    expect(at(resource, 'action.id'), at(action, 'action.id'));
    expect(at(action, 'action.resource.count'), 1);
    client.close();
  });
}

final class _DelayedBodyClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        Stream<List<int>>.fromFutures(<Future<List<int>>>[
          Future<List<int>>.delayed(
            const Duration(milliseconds: 10),
            () => <int>[1],
          ),
          Future<List<int>>.delayed(
            const Duration(milliseconds: 30),
            () => <int>[2, 3],
          ),
        ]),
        200,
        contentLength: 3,
        request: request,
      );
}

final class _BrokenBodyClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        Stream<List<int>>.error(StateError('connection reset')),
        200,
        request: request,
      );
}

final class _TimeoutClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw TimeoutException(
      'Authorization: Bearer $testClientToken '
      'https://user:password@api.example.test/orders?token=secret',
    );
  }
}
