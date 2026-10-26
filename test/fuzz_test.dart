import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';

import 'support/configuration.dart';
import 'support/fakes.dart';
import 'support/recording_transport.dart';

/// Random API use in random order, with hostile arguments. Whatever the SDK
/// sends must still satisfy the event contract (the [RecordingTransport]
/// checks every upload), and the SDK must never throw into the application.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final int seed in <int>[1, 2, 3, 4, 5, 6]) {
    test('random use with seed $seed produces only valid events', () async {
      final Random random = Random(seed);
      final RecordingTransport transport = RecordingTransport();
      final List<RumDiagnostic> diagnostics = <RumDiagnostic>[];
      final MoleSignalRumClient client = await MoleSignalRumClient.create(
        testConfiguration(
          transport,
          trackUserInteractions: true,
          trackLongTasks: true,
          trackViewPerformance: true,
          trackAppLifecycle: true,
          trackUrlQueryString: random.nextBool(),
          batchSize: 7,
          onError: diagnostics.add,
          deviceInfoProvider: FakeDeviceInfoProvider(
            const RumDeviceInfo(
              osVersion: '17.5.1',
              brand: 'Apple',
              model: 'iPhone15,2',
              batteryLevel: 0.5,
              connectivityStatus: 'connected',
              connectivityInterfaces: <String>['cellular'],
            ),
          ),
        ),
      );
      addTearDown(client.stop);

      final List<void Function()> operations = <void Function()>[
        () => client.startView(_text(random), name: _maybe(random, _text)),
        () => client.stopView(_text(random)),
        () => client.addTiming(_text(random)),
        () => client.addAction(
          _text(random),
          type:
              RumActionType.values[random.nextInt(RumActionType.values.length)],
          context: _context(random),
        ),
        () => client.recordTap(
          name: _text(random),
          position: Offset(
            random.nextDouble() * 2000 - 100,
            random.nextDouble() * 2000,
          ),
          explicit: random.nextBool(),
          targetSize: random.nextBool()
              ? Size(random.nextDouble() * 500, random.nextDouble() * 500)
              : null,
          context: _context(random),
        ),
        client.recordBack,
        () => client.addError(
          _error(random),
          stackTrace: random.nextBool()
              ? StackTrace.fromString(_stack(random))
              : null,
          source: RumErrorSource
              .values[random.nextInt(RumErrorSource.values.length)],
          type: _maybe(random, _text),
          fingerprint: _maybe(random, (Random r) => 'f' * r.nextInt(300)),
          context: _context(random),
        ),
        () => client.recordCapturedError(
          _error(random),
          stackTrace: StackTrace.fromString(_stack(random)),
          meta: _context(random),
          fatal: random.nextBool(),
        ),
        () => client.startResource(
          'k${random.nextInt(6)}',
          _method(random),
          Uri.parse(_url(random)),
        ),
        () => client.stopResource(
          'k${random.nextInt(6)}',
          statusCode: _maybe(random, (Random r) => r.nextInt(700)),
          size: _maybe(random, (Random r) => r.nextInt(1 << 30)),
          traceContext: random.nextBool()
              ? const RumTraceContext(
                  traceId: '4bf92f3577b34da6a3ce929d0e0e4736',
                  spanId: '00f067aa0ba902b7',
                )
              : const RumTraceContext(traceId: 'UPPER', spanId: 'nope'),
        ),
        () => client.stopResourceWithError(
          'k${random.nextInt(6)}',
          _error(random),
        ),
        () => client.addResource(
          RumResource(
            method: _method(random),
            url: Uri.parse(_url(random)),
            duration: Duration(microseconds: _wide(random)),
            statusCode: _maybe(random, (Random r) => r.nextInt(700)),
            responseSize: _maybe(random, (Random r) => r.nextInt(1 << 30)),
            errorType: random.nextInt(4) == 0 ? 'timeout' : null,
          ),
        ),
        () => client.addResource(
          RumResource(
            method: 'GET',
            url: Uri.parse('https://api.example.test/huge'),
            duration: const Duration(days: 4000000),
            startTime: DateTime.fromMillisecondsSinceEpoch(0),
          ),
        ),
        () =>
            client.startDurationVital(_text(random), context: _context(random)),
        () => client.stopDurationVital(_text(random)),
        () => client.addDurationVital(
          _text(random),
          Duration(microseconds: _wide(random)),
          description: _maybe(random, _text),
        ),
        () => client.addFeatureFlagEvaluation(_text(random), _value(random, 0)),
        () => random.nextBool()
            ? client.setUser(
                RumUser(
                  id: 'u${random.nextInt(9)}',
                  attributes: _context(random),
                ),
              )
            : client.clearUser(),
        () => client.setAccount(RumAccount(id: 'a${random.nextInt(9)}')),
        () => client.setGlobalContext(_context(random)),
        () => client.setGlobalContextProperty(_text(random), _value(random, 0)),
        () => client.handleLifecycleState(
          AppLifecycleState.values[random.nextInt(
            AppLifecycleState.values.length,
          )],
        ),
        () => client.recordFrameTimings(<FrameTiming>[
          syntheticFrame(
            vsyncStart: DateTime.now().subtract(
              Duration(milliseconds: random.nextInt(2000)),
            ),
            build: Duration(microseconds: random.nextInt(900000)),
            raster: Duration(microseconds: random.nextInt(900000)),
            epochWallTime: random.nextBool(),
            monotonicOrigin: _wide(random),
          ),
        ]),
        () => client.sessionManager.active().lastActivityMicros -=
            random.nextInt(4) == 0
            ? const Duration(minutes: 20).inMicroseconds
            : 0,
        () => unawaited(client.flush()),
      ];

      for (int step = 0; step < 400; step += 1) {
        operations[random.nextInt(operations.length)]();
        if (step % 25 == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      }
      await client.flush();
      await client.stop();

      expect(transport.events, isNotEmpty);
      expect(
        diagnostics
            .map((RumDiagnostic d) => d.message)
            .where((String m) => m.contains('failed') && !m.contains('upload')),
        isEmpty,
        reason: 'the SDK reported internal failures',
      );
    });
  }
}

/// An integer up to about 2^40 (`Random.nextInt` stops at 2^32).
int _wide(Random random) => random.nextInt(1 << 32) * (1 + random.nextInt(255));

String _text(Random random) {
  const List<String> samples = <String>[
    '',
    ' ',
    '/',
    '/checkout?token=secret&x=1#frag',
    'Checkout',
    'ünïcödé 终端 🧪',
    'with space and ! punctuation',
    'a.b-c_d@e\$f',
    'line\nbreak',
    '🧪',
  ];
  return random.nextInt(8) == 0
      ? 'x' * (1 + random.nextInt(600))
      : samples[random.nextInt(samples.length)];
}

T? _maybe<T>(Random random, T Function(Random random) make) =>
    random.nextBool() ? make(random) : null;

String _method(Random random) =>
    const <String>['GET', 'post', 'PROPFIND', '', 'OPTIONS'][random.nextInt(5)];

String _url(Random random) => const <String>[
  'https://api.example.test/orders?token=abc',
  'https://user:pw@api.example.test:8443/a/b',
  'http://127.0.0.1:8080/',
  'https://rum.example.test/api/v1/rum/events',
  'https://api.example.test/ünï',
][random.nextInt(5)];

Object _error(Random random) => switch (random.nextInt(6)) {
  0 => 'plain string',
  1 => StateError(_text(random)),
  2 => TimeoutException(_text(random)),
  3 => const _Silent(),
  4 => _Huge(),
  _ => FormatException(_text(random), 'source', 3),
};

String _stack(Random random) => switch (random.nextInt(5)) {
  0 =>
    '#0 Cart.total (package:app/cart.dart:12:7)\n#1 main (package:app/main.dart:3:1)',
  1 =>
    '*** ***\nbuild_id: \'abcdef\'\nisolate_dso_base: 1000\n    #00 abs 0000000000001234 virt 0000000000000234 _kDart+0x1',
  2 => 'at minified (https://cdn.example.test/main.dart.js?token=x:0:0)',
  3 => '',
  _ => List<String>.generate(
    300,
    (int i) => '#$i f$i (package:a/a.dart:$i:1)',
  ).join('\n'),
};

Map<String, Object?> _context(Random random) => <String, Object?>{
  for (int i = 0; i < random.nextInt(4); i += 1)
    _text(random): _value(random, 0),
};

Object? _value(Random random, int depth) => switch (random.nextInt(
  depth > 2 ? 6 : 9,
)) {
  0 => null,
  1 => random.nextInt(1 << 30),
  2 => random.nextDouble() * 1e9,
  3 => double.nan,
  4 => double.infinity,
  5 => _text(random),
  6 => <Object?>[
    for (int i = 0; i < random.nextInt(4); i += 1) _value(random, depth + 1),
  ],
  7 => <String, Object?>{'k': _value(random, depth + 1), 'password': 'x'},
  _ => DateTime.fromMillisecondsSinceEpoch(_wide(random)),
};

final class _Silent {
  const _Silent();

  @override
  String toString() => '';
}

final class _Huge {
  @override
  String toString() => 'huge ' * 5000;
}
