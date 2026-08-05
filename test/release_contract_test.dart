import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';
import 'package:molesignal_flutter/src/replay/capture.dart';

const String _clientToken =
    'msrum_aB3kZ1xT9pQrU7nM_dFgHjKl8eRvNcWxYz4tBmEqPaS2vG6Qz';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'build identity and structured mobile frames use artifact contract',
    () async {
      final _RecordingTransport transport = _RecordingTransport();
      final MoleSignalRumClient client = await MoleSignalRumClient.create(
        _configuration(transport, defaultPrivacyLevel: RumPrivacyLevel.allow),
      );
      client.attachReplayCapture(_MetadataReplayCapture());
      client.startSessionReplayRecording();
      client.startView('Checkout', path: '/checkout');
      client.addResource(
        RumResource(
          method: 'POST',
          url: Uri.parse('https://api.example.test/pay?token=secret'),
          duration: const Duration(microseconds: 12345),
          requestSize: 32,
          responseSize: 64,
          status: 201,
        ),
      );
      client.addError(
        StateError(
          'failed with Authorization: Bearer $_clientToken at '
          'https://user:password@example.test/path?token=secret',
        ),
        stackTrace: StackTrace.fromString(
          '#0 Checkout.pay (/Users/alice/work/app/lib/checkout.dart:8:0)',
        ),
        frames: const <RumStackFrame>[
          RumStackFrame(
            artifactKind: RumArtifactKind.androidNativeSymbols,
            module: '/data/app/private/lib/arm64/libpayments.so',
            function: 'payments_crash',
            instructionAddress: '0x1010',
            imageAddress: '0x1000',
            relativeAddress: '0x10',
          ),
        ],
      );
      client.addPerformanceMetric(
        const RumPerformanceMetric(
          kind: RumPerformanceMetricKind.memory,
          value: 4096,
          unit: RumMetricUnit.byte,
        ),
      );
      await client.flush();
      await client.stop();

      for (final RumTransportRequest request in transport.requests) {
        if (request.kind == RumEventKind.replay) continue;
        for (final Map<String, dynamic> event in _events(request)) {
          expect(event['application'], 'checkout-mobile');
          expect(event['service'], 'checkout-app');
          expect(event['version'], '1.2.3+4');
          expect(event['platform'], 'android');
          expect(event['architecture'], 'arm64');
          expect(event['debug_id'], 'build-android-arm64-42');
          expect(event['session_sequence'], greaterThan(0));
        }
      }

      final Map<String, dynamic> error = transport
          .events(RumEventKind.error)
          .single;
      expect(jsonEncode(error), isNot(contains(_clientToken)));
      expect(jsonEncode(error), isNot(contains('/Users/alice')));
      expect(jsonEncode(error), isNot(contains('user:password')));
      expect(jsonEncode(error), isNot(contains('token=secret')));
      final Map<String, dynamic> details = Map<String, dynamic>.from(
        error['error']! as Map<dynamic, dynamic>,
      );
      final List<Map<String, dynamic>> stack =
          (details['stack']! as List<dynamic>)
              .map(
                (dynamic value) =>
                    Map<String, dynamic>.from(value as Map<dynamic, dynamic>),
              )
              .toList(growable: false);
      expect(stack[0]['artifact_kind'], 'android_native_symbols');
      expect(stack[0]['module'], 'libpayments.so');
      expect(stack[0]['relative_address'], '0x10');
      expect(stack[0]['debug_id'], 'build-android-arm64-42');
      expect(stack[1]['artifact_kind'], 'flutter_symbols');
      expect(stack[1]['file'], 'lib/checkout.dart');
      expect(stack[1]['line'], 8);
      expect(stack[1]['column'], 1);
      expect(details['raw_stack'], isNot(contains('/Users/alice')));

      final Map<String, dynamic> resource = transport
          .events(RumEventKind.action)
          .firstWhere(
            (Map<String, dynamic> event) => event['type'] == 'resource',
          );
      expect(resource['url'], 'https://api.example.test/pay');
      expect(resource['duration_us'], 12345);
      final Map<String, dynamic> resourcePayload = Map<String, dynamic>.from(
        resource['payload']! as Map<dynamic, dynamic>,
      );
      expect(resourcePayload['metric_unit'], 'microsecond');
      expect(resourcePayload['clock'], 'monotonic');
      expect(resourcePayload['request_size'], 32);
      expect(resourcePayload['response_size'], 64);

      final List<RumTransportRequest> replayRequests = transport.requests
          .where(
            (RumTransportRequest request) =>
                request.kind == RumEventKind.replay,
          )
          .toList(growable: false);
      expect(replayRequests, isNotEmpty);
      for (final RumTransportRequest request in replayRequests) {
        final Map<String, dynamic> replay = Map<String, dynamic>.from(
          jsonDecode(request.body) as Map<dynamic, dynamic>,
        );
        expect(replay['application'], 'checkout-mobile');
        final List<dynamic> replayEvents = replay['events']! as List<dynamic>;
        for (final dynamic raw in replayEvents) {
          final Map<dynamic, dynamic> event = raw as Map<dynamic, dynamic>;
          expect(event['application'], 'checkout-mobile');
          expect(event['service'], 'checkout-app');
          expect(event['version'], '1.2.3+4');
          expect(event['platform'], 'android');
          expect(event['architecture'], 'arm64');
          expect(event['debug_id'], 'build-android-arm64-42');
        }
      }

      final Map<String, dynamic> finalSession = transport
          .events(RumEventKind.session)
          .firstWhere((Map<String, dynamic> event) => event['phase'] == 'end');
      expect(finalSession['view_count'], 1);
      expect(finalSession['resource_count'], 1);
      expect(finalSession['error_count'], 1);
      expect(finalSession['action_count'], 0);
      expect(finalSession['duration_us'], greaterThanOrEqualTo(0));
      expect(finalSession['last_activity_micros'], isA<int>());
      expect(finalSession['end_reason'], 'stopped');
      expect(finalSession['last_page'], '/checkout');
    },
  );

  test(
    'Flutter Web frames stay sourcemap frames with one-based locations',
    () async {
      final _RecordingTransport transport = _RecordingTransport();
      final MoleSignalRumClient client = await MoleSignalRumClient.create(
        _configuration(
          transport,
          platform: 'flutter',
          architecture: 'javascript',
          debugId: 'web-build-42',
        ),
      );
      try {
        client.addError(
          StateError('web failure'),
          stackTrace: StackTrace.fromString(
            'at minified (https://cdn.example.test/main.dart.js?token=x:0:0)',
          ),
          frames: const <RumStackFrame>[
            RumStackFrame(
              artifactKind: RumArtifactKind.flutterSymbols,
              file: 'main.wasm',
              line: 0,
              column: 0,
              instructionAddress: '0x1234',
            ),
          ],
        );
        await client.flush();
        final Map<String, dynamic> error = transport
            .events(RumEventKind.error)
            .single;
        final Map<dynamic, dynamic> details =
            error['error']! as Map<dynamic, dynamic>;
        final List<dynamic> frames = details['stack']! as List<dynamic>;
        final Map<dynamic, dynamic> frame =
            frames.last as Map<dynamic, dynamic>;
        expect(error['platform'], 'flutter');
        expect(error['architecture'], 'javascript');
        expect(frame['artifact_kind'], 'javascript_sourcemap');
        expect(frame['file'], 'https://cdn.example.test/main.dart.js');
        expect(frame['line'], 1);
        expect(frame['column'], 1);
        expect(frame['debug_id'], 'web-build-42');
        final Map<dynamic, dynamic> wasm =
            frames.first as Map<dynamic, dynamic>;
        expect(wasm['file'], 'main.wasm');
        expect(wasm['artifact_kind'], 'javascript_sourcemap');
        expect(wasm.containsKey('instruction_addr'), isFalse);
        expect(wasm['line'], 1);
        expect(wasm['column'], 1);
      } finally {
        await client.stop();
      }
    },
  );

  test(
    'credential format and local application binding fail clearly',
    () async {
      const String malformed = 'msrum_this-is-not-valid';
      Object? failure;
      try {
        await MoleSignalRumClient.create(
          RumConfiguration(
            applicationId: 'app-a',
            clientToken: malformed,
            site: 'https://rum.example.test',
            persistence: MemoryRumPersistence(),
          ),
        );
      } on Object catch (error) {
        failure = error;
      }
      expect(failure, isA<ArgumentError>());
      expect(
        failure.toString(),
        contains('msrum_<16 alphanumeric>_<32 alphanumeric>'),
      );
      expect(failure.toString(), isNot(contains(malformed)));

      final MemoryRumPersistence persistence = MemoryRumPersistence();
      final _RecordingTransport firstTransport = _RecordingTransport();
      final MoleSignalRumClient first = await MoleSignalRumClient.create(
        _configuration(
          firstTransport,
          applicationId: 'app-a',
          persistence: persistence,
        ),
      );
      await first.stop();
      await expectLater(
        MoleSignalRumClient.create(
          _configuration(
            _RecordingTransport(),
            applicationId: 'app-b',
            persistence: persistence,
          ),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (ArgumentError error) => error.message.toString(),
            'message',
            contains('already bound to application app-a'),
          ),
        ),
      );
    },
  );

  test('diagnostics and persisted state never contain credentials', () async {
    final List<RumDiagnostic> diagnostics = <RumDiagnostic>[];
    final MemoryRumPersistence persistence = MemoryRumPersistence();
    final MoleSignalRumClient client = await MoleSignalRumClient.create(
      _configuration(
        _ThrowingTransport(),
        persistence: persistence,
        onError: diagnostics.add,
      ),
    );
    client.addAction(
      'failed $_clientToken',
      context: const <String, Object?>{
        'authorization': 'Bearer secret',
        'url': 'https://user:password@example.test/path?token=secret',
      },
    );
    await client.flush();
    await client.stop();

    final String diagnosticText = diagnostics
        .map(
          (RumDiagnostic value) =>
              '${value.message}|${value.cause}|${value.stackTrace}',
        )
        .join('\n');
    expect(diagnosticText, isNot(contains(_clientToken)));
    expect(diagnosticText, isNot(contains('Bearer secret')));
    expect(diagnosticText, isNot(contains('user:password')));
    expect(diagnosticText, isNot(contains('token=secret')));
    final String persisted = persistence.values.values.join('\n');
    expect(persisted, isNot(contains(_clientToken)));
    expect(persisted, isNot(contains('Bearer secret')));
    expect(persisted, isNot(contains('user:password')));
    expect(persisted, isNot(contains('token=secret')));
  });

  test(
    'performance values reject negative, overflow, and invalid timestamps',
    () async {
      final MoleSignalRumClient client = await MoleSignalRumClient.create(
        _configuration(_RecordingTransport()),
      );
      try {
        expect(
          () => client.addPerformanceMetric(
            const RumPerformanceMetric(
              kind: RumPerformanceMetricKind.memory,
              value: -1,
              unit: RumMetricUnit.byte,
            ),
          ),
          throwsArgumentError,
        );
        expect(
          () => client.addPerformanceMetric(
            const RumPerformanceMetric(
              kind: RumPerformanceMetricKind.anr,
              value: 1,
              unit: RumMetricUnit.count,
              timestampMicros: 0,
            ),
          ),
          throwsArgumentError,
        );
        expect(
          () => client.addPerformanceMetric(
            const RumPerformanceMetric(
              kind: RumPerformanceMetricKind.memory,
              value: 9007199254740992,
              unit: RumMetricUnit.byte,
            ),
          ),
          throwsArgumentError,
        );
      } finally {
        await client.stop();
      }
    },
  );
}

RumConfiguration _configuration(
  RumTransport transport, {
  String applicationId = 'checkout-mobile',
  String platform = 'android',
  String architecture = 'arm64',
  String debugId = 'build-android-arm64-42',
  RumPrivacyLevel defaultPrivacyLevel = RumPrivacyLevel.mask,
  MemoryRumPersistence? persistence,
  RumDiagnosticHandler? onError,
}) => RumConfiguration(
  applicationId: applicationId,
  clientToken: _clientToken,
  site: 'https://rum.example.test',
  service: 'checkout-app',
  env: 'production',
  version: '1.2.3+4',
  platform: platform,
  architecture: architecture,
  debugId: debugId,
  sessionReplaySampleRate: 100,
  defaultPrivacyLevel: defaultPrivacyLevel,
  trackFlutterErrors: false,
  trackPlatformErrors: false,
  trackAppLifecycle: false,
  trackLongTasks: false,
  trackViewPerformance: false,
  trackAnonymousUser: false,
  flushInterval: const Duration(minutes: 1),
  replayFlushInterval: const Duration(minutes: 1),
  transport: transport,
  persistence: persistence ?? MemoryRumPersistence(),
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

  RumTransportRequest only(RumEventKind kind) {
    final List<RumTransportRequest> values = requests
        .where((RumTransportRequest request) => request.kind == kind)
        .toList(growable: false);
    expect(values, hasLength(1));
    return values.single;
  }
}

final class _ThrowingTransport extends RumTransport {
  @override
  Future<RumTransportResponse> send(RumTransportRequest request) {
    throw StateError(
      'Authorization: Bearer $_clientToken '
      'https://user:password@example.test/path?token=secret',
    );
  }
}

final class _MetadataReplayCapture implements RumReplayCapture {
  bool _started = false;

  @override
  void start(
    String sessionId,
    RumReplayEmit emit,
    void Function() onVisualChange,
  ) {
    if (_started) return;
    _started = true;
    final int timestamp = DateTime.now().millisecondsSinceEpoch;
    emit(sessionId, <String, Object?>{
      'type': 4,
      'timestamp': timestamp,
      'data': <String, Object?>{
        'href': 'molesignal://flutter/checkout',
        'width': 100,
        'height': 100,
      },
    });
    emit(sessionId, <String, Object?>{
      'type': 2,
      'timestamp': timestamp + 1,
      'data': <String, Object?>{
        'node': <String, Object?>{
          'type': 0,
          'id': 1,
          'childNodes': <Object?>[],
        },
        'initialOffset': <String, Object?>{'left': 0, 'top': 0},
      },
    });
  }

  @override
  void stop() {}

  @override
  void recordPointer(ui.Offset position, {int? timestampMilliseconds}) {}

  @override
  void requestCapture() {}

  @override
  Future<int?> visualFingerprint({bool refresh = false}) async => null;
}
