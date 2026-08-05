import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';

const String _clientToken =
    'msrum_aB3kZ1xT9pQrU7nM_dFgHjKl8eRvNcWxYz4tBmEqPaS2vG6Qz';

void main() {
  testWidgets('navigation observer records named route views', (
    WidgetTester tester,
  ) async {
    final _RecordingTransport transport = _RecordingTransport();
    final MoleSignalRumClient rum = await _client(transport);
    try {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: <NavigatorObserver>[RumNavigationObserver(rum)],
          routes: <String, WidgetBuilder>{
            '/': (BuildContext context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.pushNamed(context, '/details'),
                child: const Text('Details'),
              ),
            ),
            '/details': (_) => const Scaffold(body: Text('Detail page')),
          },
        ),
      );
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      await rum.flush();

      final List<Map<String, dynamic>> views = transport.actions
          .where((Map<String, dynamic> event) => event['type'] == 'view')
          .toList(growable: false);
      expect(
        views.map((Map<String, dynamic> view) => view['page']),
        containsAllInOrder(<String>['/', '/details']),
      );
    } finally {
      await rum.stop();
    }
  });

  testWidgets('RumUserAction records a short tap without owning the gesture', (
    WidgetTester tester,
  ) async {
    final _RecordingTransport transport = _RecordingTransport();
    final MoleSignalRumClient rum = await _client(transport);
    int presses = 0;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RumUserAction(
              client: rum,
              name: 'Pay now',
              behavior: HitTestBehavior.opaque,
              child: TextButton(
                onPressed: () => presses += 1,
                child: const Text('Pay'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pay'));
      await tester.pump();
      await rum.flush();

      expect(presses, 1);
      final Map<String, dynamic> action = transport.actions.firstWhere(
        (Map<String, dynamic> event) => event['name'] == 'Pay now',
      );
      expect(action['type'], 'tap');
    } finally {
      await rum.stop();
    }
  });

  testWidgets('explicit action wins over automatic root tap', (
    WidgetTester tester,
  ) async {
    final _RecordingTransport transport = _RecordingTransport();
    final MoleSignalRumClient rum = await initRum(
      RumConfiguration(
        applicationId: 'widget-test',
        clientToken: _clientToken,
        site: 'https://rum.example.test',
        version: '1.0.0',
        platform: 'android',
        architecture: 'arm64',
        debugId: 'widget-build',
        trackUserInteractions: true,
        trackFlutterErrors: false,
        trackPlatformErrors: false,
        trackAppLifecycle: false,
        trackLongFrames: false,
        trackViewPerformance: false,
        trackAnonymousUser: false,
        flushInterval: const Duration(minutes: 1),
        transport: transport,
        persistence: MemoryRumPersistence(),
      ),
    );
    try {
      await tester.pumpWidget(
        RumApp(
          client: rum,
          child: MaterialApp(
            home: Scaffold(
              body: RumUserAction(
                client: rum,
                name: 'Pay now',
                behavior: HitTestBehavior.opaque,
                child: TextButton(onPressed: () {}, child: const Text('Pay')),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pay'));
      await tester.pump();
      await rum.flush();

      final List<Map<String, dynamic>> taps = transport.actions
          .where((Map<String, dynamic> event) => event['type'] == 'tap')
          .toList(growable: false);
      expect(taps, hasLength(1));
      expect(taps.single['name'], 'Pay now');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await rum.stop();
    }
  });

  test('identical views inside the deduplication window emit once', () async {
    final _RecordingTransport transport = _RecordingTransport();
    final MoleSignalRumClient rum = await _client(transport);
    try {
      rum.startView('Checkout', path: '/checkout');
      rum.startView('Checkout', path: '/checkout');
      await rum.flush();
      expect(
        transport.actions.where(
          (Map<String, dynamic> event) => event['type'] == 'view',
        ),
        hasLength(1),
      );
    } finally {
      await rum.stop();
    }
  });
}

Future<MoleSignalRumClient> _client(_RecordingTransport transport) => initRum(
  RumConfiguration(
    applicationId: 'widget-test',
    clientToken: _clientToken,
    site: 'https://rum.example.test',
    version: '1.0.0',
    platform: 'android',
    architecture: 'arm64',
    debugId: 'widget-build',
    trackFlutterErrors: false,
    trackPlatformErrors: false,
    trackAppLifecycle: false,
    trackLongFrames: false,
    trackViewPerformance: false,
    trackAnonymousUser: false,
    flushInterval: const Duration(minutes: 1),
    transport: transport,
    persistence: MemoryRumPersistence(),
  ),
);

final class _RecordingTransport extends RumTransport {
  final List<RumTransportRequest> requests = <RumTransportRequest>[];

  List<Map<String, dynamic>> get actions => requests
      .where(
        (RumTransportRequest request) => request.kind == RumEventKind.action,
      )
      .expand(
        (RumTransportRequest request) =>
            (jsonDecode(request.body) as List<dynamic>).map(
              (dynamic value) =>
                  Map<String, dynamic>.from(value as Map<dynamic, dynamic>),
            ),
      )
      .toList(growable: false);

  @override
  Future<RumTransportResponse> send(RumTransportRequest request) async {
    requests.add(request);
    return const RumTransportResponse(ok: true, status: 200);
  }
}
