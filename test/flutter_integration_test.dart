import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';

import 'support/configuration.dart';
import 'support/recording_transport.dart';

Future<MoleSignalRumClient> _client(
  RecordingTransport transport, {
  bool trackUserInteractions = false,
}) => initRum(
  testConfiguration(
    transport,
    applicationId: 'widget-test',
    trackUserInteractions: trackUserInteractions,
  ),
);

void main() {
  testWidgets('navigation observer records named route views', (
    WidgetTester tester,
  ) async {
    final RecordingTransport transport = RecordingTransport();
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

      final List<Map<String, dynamic>> views = transport.eventsOf('view');
      expect(
        views.map((Map<String, dynamic> view) => at(view, 'view.url')),
        containsAllInOrder(<String>['/', '/details']),
      );
      expect(
        views.map((Map<String, dynamic> view) => at(view, 'view.name')),
        containsAllInOrder(<String>['/', '/details']),
      );
      expect(
        transport.latestViews
            .where((Map<String, dynamic> view) => at(view, 'view.url') == '/')
            .single['view']['is_active'],
        isFalse,
        reason: 'pushing /details ended the first view',
      );
      expect(
        transport.latestViews.singleWhere(
          (Map<String, dynamic> view) => at(view, 'view.url') == '/details',
        )['view']['is_active'],
        isTrue,
      );
    } finally {
      await rum.stop();
    }
  });

  testWidgets('popping shows the previous view again as a new view', (
    WidgetTester tester,
  ) async {
    final RecordingTransport transport = RecordingTransport();
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
            '/details': (BuildContext context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ),
          },
        ),
      );
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await rum.flush();

      final List<Map<String, dynamic>> views = transport.latestViews;
      expect(
        views.map((Map<String, dynamic> view) => at(view, 'view.url')),
        <String>['/', '/details', '/'],
      );
      expect(
        at(views.first, 'view.id'),
        isNot(at(views.last, 'view.id')),
        reason: 'each display of a screen is its own view',
      );
    } finally {
      await rum.stop();
    }
  });

  testWidgets('unnamed routes are not views', (WidgetTester tester) async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient rum = await _client(transport);
    try {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: <NavigatorObserver>[RumNavigationObserver(rum)],
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const AlertDialog(title: Text('Hi')),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await rum.flush();

      expect(
        transport.latestViews.map(
          (Map<String, dynamic> v) => at(v, 'view.url'),
        ),
        <String>['/'],
      );
    } finally {
      await rum.stop();
    }
  });

  testWidgets('RumUserAction records a short tap without owning the gesture', (
    WidgetTester tester,
  ) async {
    final RecordingTransport transport = RecordingTransport();
    // An explicit tap does not depend on automatic interaction tracking.
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
      final Map<String, dynamic> action = transport.eventsOf('action').single;
      expect(at(action, 'action.type'), 'tap');
      expect(at(action, 'action.target.name'), 'Pay now');
      expect(at(action, 'action.name_source'), 'custom_attribute');
      expect(at(action, 'action.target.width'), isA<int>());
      expect(at(action, 'action.position.x'), isA<int>());
    } finally {
      await rum.stop();
    }
  });

  testWidgets('explicit action wins over automatic root tap', (
    WidgetTester tester,
  ) async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient rum = await _client(
      transport,
      trackUserInteractions: true,
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

      final List<Map<String, dynamic>> taps = transport.eventsOf('action');
      expect(taps, hasLength(1));
      expect(at(taps.single, 'action.target.name'), 'Pay now');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await rum.stop();
    }
  });

  testWidgets('RumApp names automatic taps generically and sizes the target', (
    WidgetTester tester,
  ) async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient rum = await _client(
      transport,
      trackUserInteractions: true,
    );
    try {
      await tester.pumpWidget(
        RumApp(
          client: rum,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () {},
                  child: const Text('secret account number'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('secret account number'));
      await tester.pump();
      await rum.flush();

      final Map<String, dynamic> action = transport.eventsOf('action').single;
      expect(at(action, 'action.target.name'), 'Tap');
      expect(at(action, 'action.name_source'), 'mask_placeholder');
      expect(at(action, 'action.target.width')! as int, greaterThan(0));
      expect(at(action, 'action.target.height')! as int, greaterThan(0));
      expect(transport.requests.single.body, isNot(contains('secret account')));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await rum.stop();
    }
  });

  testWidgets(
    'RumApp does not listen to taps unless interactions are tracked',
    (WidgetTester tester) async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient rum = await _client(transport);
      try {
        await tester.pumpWidget(
          RumApp(
            client: rum,
            child: MaterialApp(
              home: Scaffold(
                body: Center(
                  child: TextButton(onPressed: () {}, child: const Text('Tap')),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(find.text('Tap'));
        await tester.pump();
        await rum.flush();

        expect(transport.eventsOf('action'), isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await rum.stop();
      }
    },
  );

  testWidgets('RumApp reports repeated taps as a rage tap', (
    WidgetTester tester,
  ) async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient rum = await _client(
      transport,
      trackUserInteractions: true,
    );
    int presses = 0;
    try {
      await tester.pumpWidget(
        RumApp(
          client: rum,
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
      await rum.flush();

      expect(presses, 3);
      final List<Map<String, dynamic>> actions = transport.eventsOf('action');
      expect(actions, hasLength(3));
      expect(
        actions.map(
          (Map<String, dynamic> action) =>
              at(action, 'action.frustration.type'),
        ),
        <Object?>[
          null,
          null,
          <Object?>['rage_tap'],
        ],
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await rum.stop();
    }
  });

  testWidgets(
    'an error reported while a tap is handled makes it an error tap',
    (WidgetTester tester) async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient rum = await _client(
        transport,
        trackUserInteractions: true,
      );
      try {
        await tester.pumpWidget(
          RumApp(
            client: rum,
            child: MaterialApp(
              home: Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () {
                      rum.addError(StateError('handler failed'));
                    },
                    child: const Text('Pay'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(find.text('Pay'));
        await tester.pump();
        await rum.flush();

        final Map<String, dynamic> action = transport.eventsOf('action').single;
        expect(at(action, 'action.frustration.type'), <Object?>['error_tap']);
        expect(
          at(transport.eventsOf('error').single, 'action.id'),
          at(action, 'action.id'),
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await rum.stop();
      }
    },
  );

  test('identical views inside the deduplication window emit once', () async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient rum = await _client(transport);
    try {
      rum.startView('/checkout');
      rum.startView('/checkout');
      await rum.flush();
      expect(transport.latestViews, hasLength(1));
    } finally {
      await rum.stop();
    }
  });
}
