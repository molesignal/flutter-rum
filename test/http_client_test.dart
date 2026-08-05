import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';

const String _clientToken =
    'msrum_aB3kZ1xT9pQrU7nM_dFgHjKl8eRvNcWxYz4tBmEqPaS2vG6Qz';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('HTTP wrapper records resources and W3C trace context', () async {
    const String traceId = '4bf92f3577b34da6a3ce929d0e0e4736';
    const String parentSpanId = '00f067aa0ba902b7';
    final _RecordingTransport transport = _RecordingTransport();
    final MoleSignalRumClient rum = await initRum(
      RumConfiguration(
        applicationId: 'shop-mobile',
        clientToken: _clientToken,
        site: 'https://rum.example.test/api/v1',
        service: 'shop-app',
        trackFlutterErrors: false,
        trackPlatformErrors: false,
        trackAppLifecycle: false,
        trackLongFrames: false,
        trackAnonymousUser: false,
        flushInterval: const Duration(minutes: 1),
        transport: transport,
        persistence: MemoryRumPersistence(),
      ),
    );
    addTearDown(rum.stop);
    final MockClient inner = MockClient(
      (http.Request request) async => http.Response(
        'abc',
        200,
        headers: <String, String>{
          'traceparent': '00-$traceId-$parentSpanId-01',
          'content-length': '3',
        },
      ),
    );
    final MoleSignalHttpClient client = MoleSignalHttpClient(rum, inner: inner);

    await client.get(
      Uri.parse('https://api.example.test/orders?secret=value'),
      headers: const <String, String>{
        'traceparent': '00-$traceId-1111111111111111-01',
      },
    );
    await rum.flush();

    expect(
      transport.requests.any(
        (RumTransportRequest request) =>
            request.kind == RumEventKind.action &&
            request.url.toString() ==
                'https://rum.example.test/api/v1/rum/actions',
      ),
      isTrue,
    );
    final List<Map<String, dynamic>> actions = transport.requests
        .where(
          (RumTransportRequest request) => request.kind == RumEventKind.action,
        )
        .expand(_events)
        .toList(growable: false);
    final Map<String, dynamic> resource = actions.firstWhere(
      (Map<String, dynamic> event) => event['type'] == 'resource',
    );
    expect(resource['url'], 'https://api.example.test/orders');
    expect(resource['status'], 200);
    expect(resource['duration_us'], greaterThanOrEqualTo(0));
    expect(resource['trace_id'], traceId);
    expect(resource['parent_span_id'], parentSpanId);
    final Map<String, dynamic> payload = Map<String, dynamic>.from(
      resource['payload']! as Map<dynamic, dynamic>,
    );
    expect(payload['method'], 'GET');
    expect(payload['initiator'], 'package:http');
    expect(payload['response_size'], 3);
    expect(payload['body_completed'], isTrue);

    client.close();
    await rum.stop();
  });

  test('SDK and excluded URLs are not recorded', () async {
    final _RecordingTransport transport = _RecordingTransport();
    final MoleSignalRumClient rum = await initRum(
      RumConfiguration(
        applicationId: 'shop-mobile',
        clientToken: _clientToken,
        site: 'https://rum.example.test',
        excludedUrls: <Pattern>['/health', RegExp(r'/private/')],
        trackFlutterErrors: false,
        trackPlatformErrors: false,
        trackAppLifecycle: false,
        trackLongFrames: false,
        trackAnonymousUser: false,
        flushInterval: const Duration(minutes: 1),
        transport: transport,
        persistence: MemoryRumPersistence(),
      ),
    );
    addTearDown(rum.stop);
    final MoleSignalHttpClient client = MoleSignalHttpClient(
      rum,
      inner: MockClient((http.Request request) async => http.Response('', 200)),
    );

    await client.get(Uri.parse('https://api.example.test/health'));
    await client.get(Uri.parse('https://api.example.test/private/profile'));
    await rum.flush();

    expect(
      transport.requests.where(
        (RumTransportRequest request) => request.kind == RumEventKind.action,
      ),
      isEmpty,
    );
    client.close();
    await rum.stop();
  });

  test('resource duration ends only after response body completion', () async {
    final _RecordingTransport transport = _RecordingTransport();
    final MoleSignalRumClient rum = await initRum(_configuration(transport));
    addTearDown(rum.stop);
    final MoleSignalHttpClient client = MoleSignalHttpClient(
      rum,
      inner: _DelayedBodyClient(),
    );

    final Stopwatch elapsed = Stopwatch()..start();
    final http.StreamedResponse response = await client.send(
      http.Request('GET', Uri.parse('https://api.example.test/delayed')),
    );
    expect(transport.requests.where(_isAction), isEmpty);
    final List<int> bytes = await response.stream
        .expand((value) => value)
        .toList();
    elapsed.stop();
    await rum.flush();

    expect(bytes, <int>[1, 2, 3]);
    final Map<String, dynamic> resource = transport.requests
        .where(_isAction)
        .expand(_events)
        .firstWhere(
          (Map<String, dynamic> event) => event['type'] == 'resource',
        );
    expect(resource['duration_us'], greaterThanOrEqualTo(20000));
    expect(
      resource['duration_us'],
      lessThanOrEqualTo(elapsed.elapsedMicroseconds + 100000),
    );
    final Map<dynamic, dynamic> payload =
        resource['payload']! as Map<dynamic, dynamic>;
    expect(payload['response_size'], 3);
    expect(payload['body_completed'], isTrue);

    client.close();
  });

  test('transport failures use stable sanitized error fields', () async {
    final _RecordingTransport transport = _RecordingTransport();
    final MoleSignalRumClient rum = await initRum(_configuration(transport));
    addTearDown(rum.stop);
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
    final Map<String, dynamic> resource = transport.requests
        .where(_isAction)
        .expand(_events)
        .firstWhere(
          (Map<String, dynamic> event) => event['type'] == 'resource',
        );
    expect(resource['url'], 'https://api.example.test/orders');
    final Map<dynamic, dynamic> payload =
        resource['payload']! as Map<dynamic, dynamic>;
    expect(payload['error_type'], 'timeout');
    expect(payload['error_code'], 'timeout');
    expect(jsonEncode(payload), isNot(contains(_clientToken)));
    expect(jsonEncode(payload), isNot(contains('user:password')));
    expect(jsonEncode(payload), isNot(contains('token=secret')));

    client.close();
  });
}

RumConfiguration _configuration(RumTransport transport) => RumConfiguration(
  applicationId: 'shop-mobile',
  clientToken: _clientToken,
  site: 'https://rum.example.test',
  service: 'shop-app',
  version: '1.0.0',
  platform: 'android',
  architecture: 'arm64',
  debugId: 'http-build',
  trackFlutterErrors: false,
  trackPlatformErrors: false,
  trackAppLifecycle: false,
  trackLongFrames: false,
  trackViewPerformance: false,
  trackAnonymousUser: false,
  flushInterval: const Duration(minutes: 1),
  transport: transport,
  persistence: MemoryRumPersistence(),
);

bool _isAction(RumTransportRequest request) =>
    request.kind == RumEventKind.action;

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

final class _TimeoutClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw TimeoutException(
      'Authorization: Bearer $_clientToken '
      'https://user:password@api.example.test/orders?token=secret',
    );
  }
}
