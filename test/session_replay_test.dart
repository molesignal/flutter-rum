import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';
import 'package:molesignal_flutter/src/replay/capture.dart';

const String _clientToken =
    'msrum_aB3kZ1xT9pQrU7nM_dFgHjKl8eRvNcWxYz4tBmEqPaS2vG6Qz';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'RumApp emits playable rrweb snapshots after masking Flutter text',
    (WidgetTester tester) async {
      final _RecordingTransport transport = _RecordingTransport();
      final MoleSignalRumClient client = await initRum(
        _configuration(
          transport,
          replaySampleRate: 100,
          replay: const RumSessionReplayConfiguration(
            captureInterval: Duration(minutes: 10),
            pixelRatio: 0.25,
            maskColorValue: 0xFF12AB34,
          ),
        ),
      );
      try {
        await tester.pumpWidget(
          RumApp(
            client: client,
            child: const MaterialApp(
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 120,
                    height: 50,
                    child: ColoredBox(
                      color: Color(0xFFFFFFFF),
                      child: Text('private account balance'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        await _waitForReplay(tester, transport);
        final Map<String, dynamic> segment = _replaySegment(
          transport.replayRequests.single,
        );
        expect(segment['session_id'], startsWith('ses_'));
        expect(segment['seq'], 1);
        final List<Map<String, dynamic>> events = _replayEvents(segment);
        expect(
          events.map((Map<String, dynamic> event) => event['type']),
          containsAllInOrder(<int>[4, 2]),
        );

        final Map<String, dynamic> full = events.firstWhere(
          (Map<String, dynamic> event) => event['type'] == 2,
        );
        final String imageUrl = _snapshotImageUrl(full);
        expect(imageUrl, startsWith('data:image/png;base64,'));
        expect(imageUrl, isNot(contains('private account balance')));

        final Uint8List png = base64Decode(imageUrl.split(',').last);
        final List<int>? centerPixel = await tester.runAsync<List<int>?>(
          () async {
            final ui.Codec codec = await ui.instantiateImageCodec(png);
            try {
              final ui.FrameInfo frame = await codec.getNextFrame();
              try {
                final ByteData? pixels = await frame.image.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                );
                if (pixels == null) return null;
                final int x = frame.image.width ~/ 2;
                final int y = frame.image.height ~/ 2;
                final int offset = (y * frame.image.width + x) * 4;
                return <int>[
                  pixels.getUint8(offset),
                  pixels.getUint8(offset + 1),
                  pixels.getUint8(offset + 2),
                  pixels.getUint8(offset + 3),
                ];
              } finally {
                frame.image.dispose();
              }
            } finally {
              codec.dispose();
            }
          },
        );
        expect(centerPixel, <int>[0x12, 0xAB, 0x34, 0xFF]);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await client.stop();
      }
    },
  );

  test(
    'manual replay override records a zero-replay-sampled session',
    () async {
      final _RecordingTransport transport = _RecordingTransport();
      final MoleSignalRumClient client = await initRum(
        _configuration(transport, replaySampleRate: 0),
      );
      final _FakeReplayCapture capture = _FakeReplayCapture();
      try {
        client.attachReplayCapture(capture);
        await client.flush();
        expect(transport.replayRequests, isEmpty);

        client.startSessionReplayRecording();
        await client.flush();
        expect(transport.replayRequests, hasLength(1));
        expect(_replaySegment(transport.replayRequests.single)['seq'], 1);

        client.stopSessionReplayRecording();
        expect(capture.active, isFalse);
      } finally {
        await client.stop();
      }
    },
  );

  test('replay retry preserves the assigned sequence and payload', () async {
    final _RetryReplayTransport transport = _RetryReplayTransport();
    final MoleSignalRumClient client = await initRum(
      _configuration(transport, replaySampleRate: 100),
    );
    try {
      client.attachReplayCapture(_FakeReplayCapture());
      await client.flush();
      await client.flush();

      expect(transport.replayRequests, hasLength(2));
      expect(
        jsonDecode(transport.replayRequests[0].body),
        jsonDecode(transport.replayRequests[1].body),
      );
      expect(_replaySegment(transport.replayRequests[0])['seq'], 1);
    } finally {
      await client.stop();
    }
  });

  test(
    'replay segment survives restart with the same sequence and payload',
    () async {
      final MemoryRumPersistence persistence = MemoryRumPersistence();
      final _AlwaysRetryReplayTransport failing = _AlwaysRetryReplayTransport();
      final MoleSignalRumClient first = await initRum(
        _configuration(
          failing,
          replaySampleRate: 100,
          persistence: persistence,
        ),
      );
      first.attachReplayCapture(_FakeReplayCapture());
      await first.flush();
      final String original = failing.replayRequests.first.body;
      await first.stop();

      final _RecordingTransport recovered = _RecordingTransport();
      final MoleSignalRumClient second = await initRum(
        _configuration(
          recovered,
          replaySampleRate: 100,
          persistence: persistence,
        ),
      );
      try {
        await second.flush();
        expect(recovered.replayRequests, hasLength(1));
        expect(
          jsonDecode(recovered.replayRequests.single.body),
          jsonDecode(original),
        );
        final Map<String, dynamic> segment = _replaySegment(
          recovered.replayRequests.single,
        );
        expect(segment['application'], 'replay-mobile');
        expect(segment['seq'], 1);
      } finally {
        await second.stop();
      }
    },
  );

  testWidgets('RumApp records automatic taps and rage clicks', (
    WidgetTester tester,
  ) async {
    final _RecordingTransport transport = _RecordingTransport();
    final MoleSignalRumClient client = await initRum(
      _configuration(
        transport,
        trackUserInteractions: true,
        trackFrustrations: true,
      ),
    );
    int presses = 0;
    try {
      await tester.pumpWidget(
        RumApp(
          client: client,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => presses += 1,
                  child: const Text('Tap target'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      for (int index = 0; index < 3; index += 1) {
        await tester.tap(find.text('Tap target'));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await client.flush();

      expect(presses, 3);
      final List<Map<String, dynamic>> actions = transport.actions;
      expect(
        actions.where((Map<String, dynamic> event) => event['type'] == 'tap'),
        hasLength(3),
      );
      expect(
        actions.any(
          (Map<String, dynamic> event) => event['type'] == 'rage_click',
        ),
        isTrue,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await client.stop();
    }
  });
}

RumConfiguration _configuration(
  RumTransport transport, {
  double replaySampleRate = 0,
  RumSessionReplayConfiguration replay = const RumSessionReplayConfiguration(),
  bool trackUserInteractions = false,
  bool? trackFrustrations,
  MemoryRumPersistence? persistence,
}) => RumConfiguration(
  applicationId: 'replay-mobile',
  clientToken: _clientToken,
  site: 'https://rum.example.test',
  service: 'replay-app',
  version: '1.0.0',
  platform: 'android',
  architecture: 'arm64',
  debugId: 'replay-build',
  sessionReplaySampleRate: replaySampleRate,
  sessionReplay: replay,
  trackUserInteractions: trackUserInteractions,
  trackFrustrations: trackFrustrations,
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
);

Future<void> _waitForReplay(
  WidgetTester tester,
  _RecordingTransport transport,
) async {
  for (int attempt = 0; attempt < 40; attempt += 1) {
    if (transport.replayRequests.isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 25));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  fail('Timed out waiting for a replay snapshot');
}

Map<String, dynamic> _replaySegment(RumTransportRequest request) =>
    Map<String, dynamic>.from(
      jsonDecode(request.body) as Map<dynamic, dynamic>,
    );

List<Map<String, dynamic>> _replayEvents(Map<String, dynamic> segment) =>
    (segment['events']! as List<dynamic>)
        .map(
          (dynamic event) =>
              Map<String, dynamic>.from(event as Map<dynamic, dynamic>),
        )
        .toList(growable: false);

String _snapshotImageUrl(Map<String, dynamic> fullSnapshot) {
  final Map<dynamic, dynamic> data =
      fullSnapshot['data']! as Map<dynamic, dynamic>;
  final Map<dynamic, dynamic> document = data['node']! as Map<dynamic, dynamic>;
  final List<dynamic> documentChildren =
      document['childNodes']! as List<dynamic>;
  final Map<dynamic, dynamic> html =
      documentChildren[1]! as Map<dynamic, dynamic>;
  final List<dynamic> htmlChildren = html['childNodes']! as List<dynamic>;
  final Map<dynamic, dynamic> body = htmlChildren[1]! as Map<dynamic, dynamic>;
  final List<dynamic> bodyChildren = body['childNodes']! as List<dynamic>;
  final Map<dynamic, dynamic> image =
      bodyChildren.single as Map<dynamic, dynamic>;
  final Map<dynamic, dynamic> attributes =
      image['attributes']! as Map<dynamic, dynamic>;
  return attributes['src']! as String;
}

class _RecordingTransport extends RumTransport {
  final List<RumTransportRequest> requests = <RumTransportRequest>[];

  List<RumTransportRequest> get replayRequests => requests
      .where(
        (RumTransportRequest request) => request.kind == RumEventKind.replay,
      )
      .toList(growable: false);

  List<Map<String, dynamic>> get actions => requests
      .where(
        (RumTransportRequest request) => request.kind == RumEventKind.action,
      )
      .expand(
        (RumTransportRequest request) =>
            (jsonDecode(request.body) as List<dynamic>).map(
              (dynamic event) =>
                  Map<String, dynamic>.from(event as Map<dynamic, dynamic>),
            ),
      )
      .toList(growable: false);

  @override
  Future<RumTransportResponse> send(RumTransportRequest request) async {
    requests.add(request);
    return const RumTransportResponse(ok: true, status: 200);
  }
}

final class _RetryReplayTransport extends _RecordingTransport {
  bool _rejected = false;

  @override
  Future<RumTransportResponse> send(RumTransportRequest request) async {
    requests.add(request);
    if (request.kind == RumEventKind.replay && !_rejected) {
      _rejected = true;
      return const RumTransportResponse(ok: false, status: 503);
    }
    return const RumTransportResponse(ok: true, status: 200);
  }
}

final class _AlwaysRetryReplayTransport extends _RecordingTransport {
  @override
  Future<RumTransportResponse> send(RumTransportRequest request) async {
    requests.add(request);
    if (request.kind == RumEventKind.replay) {
      return const RumTransportResponse(ok: false, status: 503);
    }
    return const RumTransportResponse(ok: true, status: 200);
  }
}

final class _FakeReplayCapture implements RumReplayCapture {
  String? _sessionId;
  bool active = false;

  @override
  void start(
    String sessionId,
    RumReplayEmit emit,
    void Function() onVisualChange,
  ) {
    if (active && _sessionId == sessionId) return;
    active = true;
    _sessionId = sessionId;
    final int timestamp = DateTime.now().millisecondsSinceEpoch;
    emit(sessionId, <String, Object?>{
      'type': 4,
      'timestamp': timestamp,
      'data': <String, Object?>{
        'href': 'molesignal://flutter/',
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
  void stop() {
    active = false;
    _sessionId = null;
  }

  @override
  void recordPointer(ui.Offset position, {int? timestampMilliseconds}) {}

  @override
  void requestCapture() {}

  @override
  Future<int?> visualFingerprint({bool refresh = false}) async => null;
}
