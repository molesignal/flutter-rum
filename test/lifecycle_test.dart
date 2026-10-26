import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';

import 'support/configuration.dart';
import 'support/fakes.dart';
import 'support/recording_transport.dart';

Future<MoleSignalRumClient> _start(
  RecordingTransport transport, {
  bool trackAppLifecycle = true,
  bool trackUserInteractions = false,
  bool trackFlutterErrors = false,
  bool trackPlatformErrors = false,
  bool trackViewPerformance = false,
  bool trackLongTasks = false,
}) => MoleSignalRumClient.create(
  testConfiguration(
    transport,
    trackAppLifecycle: trackAppLifecycle,
    trackUserInteractions: trackUserInteractions,
    trackFlutterErrors: trackFlutterErrors,
    trackPlatformErrors: trackPlatformErrors,
    trackViewPerformance: trackViewPerformance,
    trackLongTasks: trackLongTasks,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('foreground and background', () {
    test(
      'going to the background ends the view and shows it again on return',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await _start(transport);
        addTearDown(client.stop);

        client.startView('/checkout');
        client.handleLifecycleState(AppLifecycleState.paused);
        await client.flush();
        expect(at(transport.latestViews.single, 'view.is_active'), isFalse);

        client.handleLifecycleState(AppLifecycleState.resumed);
        await client.flush();

        final List<Map<String, dynamic>> views = transport.latestViews;
        expect(views, hasLength(2));
        expect(at(views[0], 'view.is_active'), isFalse);
        expect(at(views[1], 'view.is_active'), isTrue);
        expect(at(views[1], 'view.url'), '/checkout');
        expect(at(views[1], 'view.id'), isNot(at(views[0], 'view.id')));
        expect(at(views[1], 'view.loading_type'), 'view_controller_redisplay');
      },
    );

    test('an inactive app is still on screen', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await _start(transport);
      addTearDown(client.stop);

      client.startView('/checkout');
      client.handleLifecycleState(AppLifecycleState.inactive);
      client.addAction('Permission dialog');
      client.handleLifecycleState(AppLifecycleState.resumed);
      await client.flush();

      expect(transport.latestViews, hasLength(1));
      expect(at(transport.latestViews.single, 'view.is_active'), isTrue);
    });

    test(
      'events in the background belong to the view that ended and say so',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await _start(transport);
        addTearDown(client.stop);

        client.startView('/checkout');
        client.handleLifecycleState(AppLifecycleState.hidden);
        client.addError(StateError('while away'));
        client.handleLifecycleState(AppLifecycleState.resumed);
        await client.flush();

        final Map<String, dynamic> error = transport.eventsOf('error').single;
        expect(at(error, 'view.in_foreground'), isFalse);
        final Map<String, dynamic> ended = transport.latestViews.first;
        expect(at(error, 'view.id'), at(ended, 'view.id'));
        expect(at(ended, 'view.is_active'), isFalse);
        expect(
          at(ended, 'view.error.count'),
          1,
          reason: 'the ended view was reported again with the late error',
        );
      },
    );

    test('a view stopped on purpose is not shown again on return', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await _start(transport);
      addTearDown(client.stop);

      client.startView('/checkout');
      client.stopView('/checkout');
      client.handleLifecycleState(AppLifecycleState.paused);
      client.handleLifecycleState(AppLifecycleState.resumed);
      await client.flush();

      expect(transport.latestViews, hasLength(1));
    });

    test('a background flush delivers what is queued', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await _start(transport);
      addTearDown(client.stop);

      client.addAction('Before background');
      client.handleLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(transport.eventsOf('action'), hasLength(1));
    });

    test('lifecycle tracking can be switched off', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await _start(
        transport,
        trackAppLifecycle: false,
      );
      addTearDown(client.stop);

      client.startView('/checkout');
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await client.flush();

      expect(at(transport.latestViews.single, 'view.is_active'), isTrue);
    });

    testWidgets('the binding delivers lifecycle changes to the client', (
      WidgetTester tester,
    ) async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await _start(transport);
      try {
        client.startView('/checkout');
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        await client.flush();
        expect(at(transport.latestViews.single, 'view.is_active'), isFalse);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
      } finally {
        await client.stop();
      }
    });
  });

  group('session renewal', () {
    test('a view does not outlive its session', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await _start(transport);
      addTearDown(client.stop);

      client.startView('/checkout', name: 'Checkout');
      await client.flush();
      final String firstSession =
          at(transport.latestViews.single, 'session.id')! as String;

      client.sessionManager.active().lastActivityMicros =
          DateTime.now().microsecondsSinceEpoch -
          const Duration(minutes: 20).inMicroseconds;
      client.addAction('After a long idle');
      await client.flush();

      final List<Map<String, dynamic>> views = transport.latestViews;
      expect(views, hasLength(2));
      expect(at(views[0], 'session.id'), firstSession);
      expect(at(views[0], 'view.is_active'), isFalse);
      expect(at(views[1], 'session.id'), isNot(firstSession));
      expect(
        at(views[1], 'session.start')! as int,
        greaterThanOrEqualTo(at(views[0], 'session.start')! as int),
        reason: 'the renewed session began later than the one it replaced',
      );
      expect(at(views[1], 'view.name'), 'Checkout');
      expect(at(views[1], 'view.url'), '/checkout');
      expect(at(views[1], 'view.loading_type'), 'session_renewal');
      expect(at(views[1], 'view.is_active'), isTrue);
      final Map<String, dynamic> action = transport.eventsOf('action').single;
      expect(at(action, 'session.id'), at(views[1], 'session.id'));
      expect(at(action, 'session.start'), at(views[1], 'session.start'));
      expect(at(action, 'view.id'), at(views[1], 'view.id'));
      expect(at(views[1], 'view.action.count'), 1);
    });

    test('frame timings never start or extend a session', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await _start(
        transport,
        trackLongTasks: true,
        trackViewPerformance: true,
      );
      addTearDown(client.stop);

      client.startView('/checkout');
      // The first frame is the cold start, which counts as activity.
      client.recordFrameTiming(syntheticFrame(vsyncStart: DateTime.now()));
      final int idle =
          DateTime.now().microsecondsSinceEpoch -
          const Duration(minutes: 20).inMicroseconds;
      client.sessionManager.active().lastActivityMicros = idle;
      client.recordFrameTiming(
        syntheticFrame(
          vsyncStart: DateTime.now(),
          build: const Duration(milliseconds: 300),
        ),
      );
      await client.flush();

      expect(transport.eventsOf('long_task'), isEmpty);
      expect(client.sessionManager.active().lastActivityMicros, idle);
    });

    test('a restarted app resumes a session that is still valid', () async {
      final MemoryRumPersistence persistence = MemoryRumPersistence();
      final RecordingTransport first = RecordingTransport();
      final MoleSignalRumClient one = await MoleSignalRumClient.create(
        testConfiguration(first, persistence: persistence),
      );
      one.startView('/a');
      await one.stop();

      final RecordingTransport second = RecordingTransport();
      final MoleSignalRumClient two = await MoleSignalRumClient.create(
        testConfiguration(second, persistence: persistence),
      );
      two.startView('/b');
      await two.stop();

      expect(
        at(second.latestViews.single, 'session.id'),
        at(first.latestViews.single, 'session.id'),
      );
    });
  });

  group('platform hooks', () {
    testWidgets('framework and platform errors are captured and chained', (
      WidgetTester tester,
    ) async {
      final RecordingTransport transport = RecordingTransport();
      final FlutterExceptionHandler? previousFlutter = FlutterError.onError;
      final MoleSignalRumClient client = await _start(
        transport,
        trackFlutterErrors: true,
        trackPlatformErrors: true,
      );
      try {
        expect(FlutterError.onError, isNot(same(previousFlutter)));
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: FormatException('overflowed'),
            stack: StackTrace.fromString(
              '#0 build (package:app/page.dart:9:3)',
            ),
            library: 'rendering library',
            context: ErrorDescription('during layout'),
          ),
        );
        expect(tester.takeException(), isFormatException, reason: 'chained');

        final bool handled = PlatformDispatcher.instance.onError!(
          StateError('uncaught async'),
          StackTrace.fromString('#0 later (package:app/job.dart:4:1)'),
        );
        expect(handled, isFalse, reason: 'the app decides what happens next');
        await client.flush();

        final List<Map<String, dynamic>> errors = transport.eventsOf('error');
        expect(errors, hasLength(2));
        expect(at(errors[0], 'error.source'), 'source');
        expect(at(errors[0], 'error.handling'), 'unhandled');
        expect(at(errors[0], 'error.is_crash'), isFalse);
        expect(at(errors[0], 'error.type'), 'FormatException');
        expect(at(errors[0], 'error.meta.library'), 'rendering library');
        expect(
          at(errors[0], 'error.meta.diagnostics_context'),
          'during layout',
        );
        expect(at(errors[1], 'error.is_crash'), isTrue);
        expect(at(errors[1], 'error.handling'), 'unhandled');
        expect(at(errors[1], 'error.type'), 'StateError');
        expect(at(errors[1], 'error.source_type'), 'flutter');
      } finally {
        await client.stop();
      }
      expect(FlutterError.onError, same(previousFlutter), reason: 'restored');
      expect(PlatformDispatcher.instance.onError, isNull);
    });

    testWidgets('the system back button is a back action and still pops', (
      WidgetTester tester,
    ) async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await _start(
        transport,
        trackUserInteractions: true,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: <NavigatorObserver>[
              RumNavigationObserver(client),
            ],
            routes: <String, WidgetBuilder>{
              '/': (BuildContext context) => TextButton(
                onPressed: () => Navigator.pushNamed(context, '/details'),
                child: const Text('Details'),
              ),
              '/details': (_) => const Text('Detail page'),
            },
          ),
        );
        await tester.tap(find.text('Details'));
        await tester.pumpAndSettle();
        expect(find.text('Detail page'), findsOneWidget);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(
          find.text('Detail page'),
          findsNothing,
          reason: 'it still popped',
        );
        await client.flush();

        final Map<String, dynamic> back = transport.eventsOf('action').single;
        expect(at(back, 'action.type'), 'back');
        expect(at(back, 'view.url'), '/details', reason: 'the screen it left');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await client.stop();
      }
    });

    test(
      'the swipe-back gesture is a back action; a cancelled one is not',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await _start(transport);
        addTearDown(client.stop);
        final RumNavigationObserver observer = RumNavigationObserver(client);
        final MaterialPageRoute<void> home = MaterialPageRoute<void>(
          settings: const RouteSettings(name: '/'),
          builder: (_) => const SizedBox(),
        );
        final MaterialPageRoute<void> details = MaterialPageRoute<void>(
          settings: const RouteSettings(name: '/details'),
          builder: (_) => const SizedBox(),
        );

        observer.didPush(home, null);
        observer.didPush(details, home);
        observer.didStartUserGesture(details, home);
        observer.didStopUserGesture(); // cancelled
        observer.didPop(details, home); // a later, programmatic pop
        observer.didPush(details, home);
        observer.didStartUserGesture(details, home);
        observer.didPop(details, home);
        observer.didStopUserGesture();
        await client.flush();

        expect(
          transport
              .eventsOf('action')
              .map((Map<String, dynamic> e) => at(e, 'action.type')),
          <Object?>['back'],
        );
      },
    );
  });

  test('memory is sampled while a view is on screen', () async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient client = await _start(
      transport,
      trackViewPerformance: true,
    );
    addTearDown(client.stop);

    client.startView('/checkout');
    await client.flush();

    final Map<String, dynamic> view = transport.latestViews.single;
    expect(at(view, 'view.memory_max'), greaterThan(0));
    expect(at(view, 'view.memory_average'), greaterThan(0));
  });
}
