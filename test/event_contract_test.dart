import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/widgets.dart' show SizedBox;

import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';
import 'package:molesignal_flutter/src/internal/sdk_info.dart';

import 'support/configuration.dart';
import 'support/fakes.dart';
import 'support/recording_transport.dart';

/// Every event below is also checked against `v1.schema.json` by the
/// [RecordingTransport], which fails the test at its end on any violation.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<MoleSignalRumClient> startClient(
    RecordingTransport transport, {
    RumConfiguration Function(RumTransport transport)? configure,
  }) async {
    final MoleSignalRumClient client = await MoleSignalRumClient.create(
      (configure ?? testConfiguration)(transport),
    );
    addTearDown(client.stop);
    return client;
  }

  group('view', () {
    test(
      'is reported again with cumulative counts and a constant date',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(transport);

        client.startView('/products?secret=hidden', name: 'Products');
        client.addAction('Checkout started');
        client.addError(
          StateError('Cannot read total'),
          stackTrace: StackTrace.fromString(
            '#0 Cart.total (package:app/cart.dart:12:7)',
          ),
        );
        await client.flush();
        client.startView('/cart');
        await client.flush();

        final List<Map<String, dynamic>> products = transport
            .eventsOf('view')
            .where((Map<String, dynamic> e) => at(e, 'view.name') == 'Products')
            .toList();
        // Revision 1 was still queued when revision 2 was made, and a view
        // revision replaces the queued ones: the receiver only needs the latest.
        expect(
          products.map((Map<String, dynamic> e) => at(e, 'view.revision')),
          <Object?>[2, 3],
        );
        final Map<String, dynamic> running = products.first;
        expect(at(running, 'view.url'), '/products');
        expect(at(running, 'view.is_active'), isTrue);
        expect(at(running, 'view.loading_type'), 'view_controller_display');
        expect(at(running, 'view.action.count'), 1);
        expect(at(running, 'view.error.count'), 1);
        expect(at(running, 'view.crash.count'), 0);
        expect(at(running, 'view.time_spent'), isA<int>());
        expect(at(running, 'session.has_replay'), isFalse);

        final Map<String, dynamic> ended = products.last;
        expect(at(ended, 'view.is_active'), isFalse);
        expect(at(ended, 'view.action.count'), 1);
        expect(
          ended['date'],
          running['date'],
          reason: 'a view keeps the date it started at',
        );
        expect(at(ended, 'view.id'), at(running, 'view.id'));
        expect(
          at(ended, 'view.time_spent')! as int,
          greaterThanOrEqualTo(at(running, 'view.time_spent')! as int),
        );

        final Map<String, dynamic> cart = transport
            .eventsOf('view')
            .singleWhere(
              (Map<String, dynamic> e) => at(e, 'view.name') == '/cart',
            );
        expect(at(cart, 'view.revision'), 1);
        expect(at(cart, 'view.id'), isNot(at(running, 'view.id')));
      },
    );

    test(
      'an identical view inside the deduplication window is ignored',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(transport);

        client.startView('/checkout');
        client.startView('/checkout');
        await client.flush();

        expect(transport.latestViews, hasLength(1));
      },
    );

    test('stopView ends the view and the next event gets a new view', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(transport);

      client.startView('/checkout');
      client.stopView('/other');
      client.stopView('/checkout');
      await client.flush();

      final Map<String, dynamic> view = transport.latestViews.single;
      expect(at(view, 'view.is_active'), isFalse);
    });

    test(
      'custom timings are named safely and measured from the view start',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(transport);

        client.startView('/checkout');
        client.addTiming('cart ready!');
        await client.flush();

        final Map<String, dynamic> timings =
            at(transport.latestViews.single, 'view.custom_timings')!
                as Map<String, dynamic>;
        expect(timings.keys, <String>['cart_ready_']);
        expect(timings['cart_ready_'], isA<int>());
      },
    );

    test(
      'events before any view belong to an ApplicationLaunch view',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(transport);

        client.addAction('Early');
        await client.flush();

        expect(
          at(transport.latestViews.single, 'view.name'),
          'ApplicationLaunch',
        );
        expect(
          at(transport.eventsOf('action').single, 'view.id'),
          at(transport.latestViews.single, 'view.id'),
        );
      },
    );
  });

  group('action', () {
    test('a custom action carries its target and attributes', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(transport);

      client.startView('/checkout');
      client.addAction(
        'Checkout started',
        context: const <String, Object?>{'cart_size': 3, 'password': 'x'},
      );
      await client.flush();

      final Map<String, dynamic> action = transport.eventsOf('action').single;
      expect(at(action, 'action.type'), 'custom');
      expect(at(action, 'action.target.name'), 'Checkout started');
      expect(at(action, 'action.error.count'), 0);
      expect(at(action, 'context.cart_size'), 3);
      expect(at(action, 'context.password'), '[Redacted]');
      expect(action['date'], isA<int>());
      expect(at(action, 'view.url'), '/checkout');
    });

    test(
      'a tap records where and on what, without reading screen content',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(
          transport,
          configure: (RumTransport t) =>
              testConfiguration(t, trackUserInteractions: true),
        );

        client.recordTap(
          name: 'Tap',
          position: const Offset(100.4, 200.6),
          explicit: false,
          targetSize: const Size(120, 39.6),
        );
        await client.flush();

        final Map<String, dynamic> action = transport.eventsOf('action').single;
        expect(at(action, 'action.type'), 'tap');
        expect(at(action, 'action.position.x'), 100);
        expect(at(action, 'action.position.y'), 201);
        expect(at(action, 'action.target.name'), 'Tap');
        expect(at(action, 'action.target.selector'), 'flutter:interactive');
        expect(at(action, 'action.target.width'), 120);
        expect(at(action, 'action.target.height'), 40);
        expect(at(action, 'action.name_source'), 'mask_placeholder');
      },
    );

    test('three quick taps in one place make the last a rage tap', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(
        transport,
        configure: (RumTransport t) =>
            testConfiguration(t, trackUserInteractions: true),
      );

      for (int tap = 0; tap < 3; tap += 1) {
        client.recordTap(
          name: 'Tap',
          position: const Offset(50, 60),
          explicit: false,
        );
      }
      await client.flush();

      final List<Map<String, dynamic>> actions = transport.eventsOf('action');
      expect(actions, hasLength(3));
      expect(at(actions[0], 'action.frustration'), isNull);
      expect(at(actions[1], 'action.frustration'), isNull);
      expect(at(actions[2], 'action.frustration.type'), <Object?>['rage_tap']);
      expect(at(transport.latestViews.single, 'view.frustration.count'), 1);
    });

    test(
      'a tap that causes an error is an error tap and owns the error',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(
          transport,
          configure: (RumTransport t) =>
              testConfiguration(t, trackUserInteractions: true),
        );

        client.recordTap(
          name: 'Pay now',
          position: const Offset(10, 10),
          explicit: true,
        );
        client.addError(StateError('payment failed'));
        await client.flush();

        final Map<String, dynamic> action = transport.eventsOf('action').single;
        final Map<String, dynamic> error = transport.eventsOf('error').single;
        expect(at(action, 'action.frustration.type'), <Object?>['error_tap']);
        expect(at(action, 'action.error.count'), 1);
        expect(at(action, 'action.name_source'), 'custom_attribute');
        expect(at(action, 'action.target.selector'), 'flutter:Pay now');
        expect(at(error, 'action.id'), at(action, 'action.id'));
      },
    );

    test('frustrations can be switched off', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(
        transport,
        configure: (RumTransport t) => testConfiguration(
          t,
          trackUserInteractions: true,
          trackFrustrations: false,
        ),
      );

      for (int tap = 0; tap < 3; tap += 1) {
        client.recordTap(
          name: 'Tap',
          position: const Offset(50, 60),
          explicit: false,
        );
      }
      client.addError(StateError('x'));
      await client.flush();

      for (final Map<String, dynamic> action in transport.eventsOf('action')) {
        expect(at(action, 'action.frustration'), isNull);
      }
    });

    test('the system back button is a back action', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(
        transport,
        configure: (RumTransport t) =>
            testConfiguration(t, trackUserInteractions: true),
      );

      client.recordBack();
      await client.flush();

      final Map<String, dynamic> action = transport.eventsOf('action').single;
      expect(at(action, 'action.type'), 'back');
      expect(at(action, 'action.target.name'), 'Back');
    });

    test('an action completes by itself once nothing more happens', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(transport);

      client.addAction('Quiet');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      client.addError(StateError('later'));
      await client.flush();

      final Map<String, dynamic> action = transport.eventsOf('action').single;
      final Map<String, dynamic> error = transport.eventsOf('error').single;
      expect(at(action, 'action.error.count'), 0);
      expect(at(error, 'action'), isNull, reason: 'it is outside the action');
    });

    test('a request started by an action keeps it open and joins it', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(transport);

      client.addAction('Load orders');
      client.startResource(
        'r1',
        'GET',
        Uri.parse('https://api.example.test/o'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));
      client.stopResource('r1', statusCode: 200, size: 10);
      await client.flush();

      final Map<String, dynamic> action = transport.eventsOf('action').single;
      final Map<String, dynamic> resource = transport
          .eventsOf('resource')
          .single;
      expect(at(action, 'action.resource.count'), 1);
      expect(at(resource, 'action.id'), at(action, 'action.id'));
      expect(
        at(action, 'action.loading_time')! as int,
        greaterThanOrEqualTo(350000000),
        reason: 'the action lasted until its request finished',
      );
    });
  });

  group('resource', () {
    test('is a native request with nanosecond timings and trace ids', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(transport);

      client.startView('/orders');
      client.startResource(
        'r1',
        'get',
        Uri.parse('https://user:pw@api.example.test/orders?secret=1'),
      );
      client.stopResource(
        'r1',
        statusCode: 200,
        size: 2048,
        traceContext: const RumTraceContext(
          traceId: '4bf92f3577b34da6a3ce929d0e0e4736',
          spanId: '00f067aa0ba902b7',
        ),
      );
      await client.flush();

      final Map<String, dynamic> resource = transport
          .eventsOf('resource')
          .single;
      expect(at(resource, 'resource.type'), 'native');
      expect(at(resource, 'resource.method'), 'GET');
      expect(at(resource, 'resource.url'), 'https://api.example.test/orders');
      expect(at(resource, 'resource.status_code'), 200);
      expect(at(resource, 'resource.size'), 2048);
      expect(at(resource, 'resource.duration'), isA<int>());
      expect(
        at(resource, 'resource.trace_id'),
        '4bf92f3577b34da6a3ce929d0e0e4736',
      );
      expect(at(resource, 'resource.span_id'), '00f067aa0ba902b7');
      expect(at(transport.latestViews.single, 'view.resource.count'), 1);
    });

    test(
      'addResource reports a finished request at the time it started',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(transport);

        final DateTime started = DateTime.now().subtract(
          const Duration(seconds: 2),
        );
        client.addResource(
          RumResource(
            method: 'PROPFIND',
            url: Uri.parse('https://api.example.test/dav'),
            duration: const Duration(microseconds: 12345),
            startTime: started,
            statusCode: 207,
          ),
        );
        await client.flush();

        final Map<String, dynamic> resource = transport
            .eventsOf('resource')
            .single;
        expect(resource['date'], started.millisecondsSinceEpoch);
        expect(at(resource, 'resource.duration'), 12345000);
        expect(
          at(resource, 'resource.method'),
          isNull,
          reason: 'the contract only knows the standard methods',
        );
      },
    );

    test('a request without a response is also a network error', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(transport);

      client.startResource(
        'r1',
        'POST',
        Uri.parse('https://api.example.test/pay?t=1'),
      );
      client.stopResourceWithError('r1', TimeoutException('timed out'));
      await client.flush();

      final Map<String, dynamic> resource = transport
          .eventsOf('resource')
          .single;
      expect(at(resource, 'resource.status_code'), 0);
      final Map<String, dynamic> error = transport.eventsOf('error').single;
      expect(at(error, 'error.source'), 'network');
      expect(at(error, 'error.handling'), 'handled');
      expect(at(error, 'error.type'), 'timeout');
      expect(at(error, 'error.category'), 'Network');
      expect(
        at(error, 'error.message'),
        contains('POST https://api.example.test/pay'),
      );
      expect(at(error, 'error.resource.method'), 'POST');
      expect(at(error, 'error.resource.status_code'), 0);
      expect(at(error, 'error.resource.url'), 'https://api.example.test/pay');
      expect(at(error, 'error.stack'), isNull);
      expect(at(transport.latestViews.single, 'view.error.count'), 1);
    });

    test('a cancelled response body is a resource but not an error', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(transport);

      client.startResource(
        'r1',
        'GET',
        Uri.parse('https://api.example.test/big'),
      );
      client.stopResourceWithError(
        'r1',
        StateError('response body consumption cancelled'),
        statusCode: 200,
      );
      await client.flush();

      expect(transport.eventsOf('resource'), hasLength(1));
      expect(transport.eventsOf('error'), isEmpty);
    });

    test('excluded URLs, and tracking switched off, record nothing', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(
        transport,
        configure: (RumTransport t) =>
            testConfiguration(t, excludedUrls: <Pattern>['/health']),
      );

      client.startResource(
        'r1',
        'GET',
        Uri.parse('https://api.example.test/health'),
      );
      client.stopResource('r1', statusCode: 200);
      client.addResource(
        RumResource(
          method: 'GET',
          url: Uri.parse('https://rum.example.test/api/v1/rum/events'),
          duration: Duration.zero,
        ),
      );
      await client.flush();

      expect(transport.eventsOf('resource'), isEmpty);
    });
  });

  group('error', () {
    test(
      'a handled error has source, type, stack, frames and handling',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(transport);

        client.addError(
          StateError('Cannot read total'),
          stackTrace: StackTrace.fromString(
            '#0 Cart.total (package:app/cart.dart:12:7)\n'
            '#1 main (package:app/main.dart:3:1)',
          ),
          context: const <String, Object?>{'component': 'CartSummary'},
        );
        await client.flush();

        final Map<String, dynamic> error = transport.eventsOf('error').single;
        expect(at(error, 'error.source'), 'custom');
        expect(at(error, 'error.handling'), 'handled');
        expect(at(error, 'error.type'), 'StateError');
        expect(at(error, 'error.message'), contains('Cannot read total'));
        expect(at(error, 'error.is_crash'), isFalse);
        expect(at(error, 'error.source_type'), 'flutter');
        expect(at(error, 'error.category'), 'Exception');
        expect(at(error, 'error.fingerprint'), isNull);
        expect(at(error, 'error.stack'), contains('Cart.total'));
        expect(
          at(error, 'error.stack'),
          contains('package:app/cart.dart:12:7'),
        );
        final List<dynamic> frames =
            at(error, 'error.frames')! as List<dynamic>;
        expect(frames, hasLength(2));
        final Map<String, dynamic> first = frames.first as Map<String, dynamic>;
        expect(first['function'], 'Cart.total');
        expect(first['file'], 'package:app/cart.dart');
        expect(first['line'], 12);
        expect(first['column'], 7);
        expect(first['debug_id'], 'build-android-arm64-42');
        expect(first.containsKey('artifact_kind'), isFalse);
        expect(at(error, 'context.component'), 'CartSummary');
      },
    );

    test('the source, a type and a fingerprint can be chosen', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(transport);

      client.addError(
        'plain text',
        source: RumErrorSource.logger,
        type: 'PaymentDeclined',
        fingerprint: 'payment-declined',
      );
      await client.flush();

      final Map<String, dynamic> error = transport.eventsOf('error').single;
      expect(at(error, 'error.source'), 'logger');
      expect(at(error, 'error.type'), 'PaymentDeclined');
      expect(at(error, 'error.fingerprint'), 'payment-declined');
      expect(at(error, 'error.message'), 'plain text');
    });

    test('an uncaught platform error is an unhandled crash', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(transport);

      client.recordCapturedError(StateError('fatal'), fatal: true);
      client.recordCapturedError(
        FormatException('framework'),
        meta: const <String, Object?>{'library': 'widgets library'},
        fatal: false,
      );
      await client.flush();

      final List<Map<String, dynamic>> errors = transport.eventsOf('error');
      expect(errors, hasLength(2));
      expect(at(errors[0], 'error.is_crash'), isTrue);
      expect(at(errors[0], 'error.handling'), 'unhandled');
      expect(at(errors[0], 'error.source'), 'source');
      expect(at(errors[0], 'error.source_type'), 'flutter');
      expect(at(errors[1], 'error.is_crash'), isFalse);
      expect(at(errors[1], 'error.handling'), 'unhandled');
      expect(at(errors[1], 'error.meta.library'), 'widgets library');
      final Map<String, dynamic> view = transport.latestViews.single;
      expect(at(view, 'view.error.count'), 2);
      expect(at(view, 'view.crash.count'), 1);
    });

    test('an AOT stack keeps the addresses a symbol file needs', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(transport);

      client.addError(
        StateError('release failure'),
        stackTrace: StackTrace.fromString(_aotStack),
      );
      await client.flush();

      final List<dynamic> frames =
          at(transport.eventsOf('error').single, 'error.frames')!
              as List<dynamic>;
      expect(frames, hasLength(2));
      final Map<String, dynamic> first = frames.first as Map<String, dynamic>;
      expect(first['artifact_kind'], 'flutter_symbols');
      expect(first['instruction_addr'], '0x78e1d9a7b9bf');
      expect(first['image_addr'], '0x78e1d9500000');
      expect(first['relative_address'], '0x57b9bf');
      expect(first['build_id'], '5d3b4e0a1fe4a0c7a5f3d6e2b1c0a9f8');
      expect(first['debug_id'], 'build-android-arm64-42');
    });

    test('Flutter Web frames name a file and no native image', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(
        transport,
        configure: (RumTransport t) => testConfiguration(
          t,
          platform: 'flutter',
          architecture: 'javascript',
          debugId: 'web-build-42',
        ),
      );

      client.addError(
        StateError('web failure'),
        stackTrace: StackTrace.fromString(
          'at minified (https://cdn.example.test/main.dart.js?token=x:0:0)',
        ),
        frames: const <RumStackFrame>[
          RumStackFrame(
            artifactKind: RumArtifactKind.flutterSymbols,
            file: 'main.wasm',
            instructionAddress: '0x1234',
          ),
        ],
      );
      await client.flush();

      final List<dynamic> frames =
          at(transport.eventsOf('error').single, 'error.frames')!
              as List<dynamic>;
      for (final dynamic frame in frames) {
        final Map<String, dynamic> map = frame as Map<String, dynamic>;
        expect(map.containsKey('artifact_kind'), isFalse);
        expect(map.containsKey('instruction_addr'), isFalse);
        expect(map['debug_id'], 'web-build-42');
      }
      final Map<String, dynamic> web = frames.last as Map<String, dynamic>;
      expect(web['file'], 'https://cdn.example.test/main.dart.js');
      expect(web['line'], 1);
      expect(web['column'], 1);
    });

    test('the same error twice in a row is reported once', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(transport);

      client.addError(StateError('same'));
      client.addError(StateError('same'));
      await client.flush();

      expect(transport.eventsOf('error'), hasLength(1));
    });
  });

  group('long tasks and mobile vitals', () {
    test(
      'slow and frozen frames are long tasks; views keep frame metrics',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(
          transport,
          configure: (RumTransport t) => testConfiguration(
            t,
            trackLongTasks: true,
            trackViewPerformance: true,
          ),
        );

        client.startView('/checkout');
        final DateTime begin = DateTime.now();
        client.recordFrameTiming(
          syntheticFrame(
            vsyncStart: begin.add(const Duration(milliseconds: 5)),
            build: const Duration(milliseconds: 3),
            raster: const Duration(milliseconds: 4),
          ),
        );
        client.recordFrameTiming(
          syntheticFrame(
            vsyncStart: begin.add(const Duration(milliseconds: 50)),
            build: const Duration(milliseconds: 120),
            raster: const Duration(milliseconds: 30),
          ),
        );
        client.recordFrameTiming(
          syntheticFrame(
            vsyncStart: begin.add(const Duration(milliseconds: 300)),
            build: const Duration(milliseconds: 800),
            raster: const Duration(milliseconds: 10),
          ),
        );
        await client.flush();

        final List<Map<String, dynamic>> tasks = transport.eventsOf(
          'long_task',
        );
        expect(tasks, hasLength(2));
        expect(at(tasks[0], 'long_task.duration'), 151000000);
        expect(at(tasks[0], 'long_task.is_frozen_frame'), isFalse);
        expect(at(tasks[1], 'long_task.duration'), 811000000);
        expect(at(tasks[1], 'long_task.is_frozen_frame'), isTrue);
        expect(tasks[1]['date'], isA<int>());

        final Map<String, dynamic> view = transport.latestViews.single;
        expect(at(view, 'view.long_task.count'), 2);
        expect(at(view, 'view.frozen_frame.count'), 1);
        expect(at(view, 'view.flutter_build_time.min'), 3000000);
        expect(at(view, 'view.flutter_build_time.max'), 800000000);
        expect(at(view, 'view.flutter_build_time.average'), 307666667);
        expect(at(view, 'view.flutter_raster_time.max'), 30000000);
        expect(at(view, 'view.refresh_rate_min'), closeTo(1.23, 0.01));
        expect(at(view, 'view.refresh_rate_average'), isA<num>());
        expect(at(view, 'view.slow_frames_rate'), greaterThan(0));
        expect(at(view, 'view.freeze_rate'), greaterThan(0));
      },
    );

    test(
      'a long task is dated inside its view, even when the engine cannot date frames',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(
          transport,
          configure: (RumTransport t) =>
              testConfiguration(t, trackLongTasks: true),
        );

        client.startView('/checkout');
        // Flutter Web stamps frames with its monotonic clock only, and reports
        // them in batches long after they were drawn.
        client.recordFrameTimings(<FrameTiming>[
          syntheticFrame(
            vsyncStart: DateTime.now(),
            epochWallTime: false,
            monotonicOrigin: 8706000,
            build: const Duration(milliseconds: 250),
          ),
          syntheticFrame(
            vsyncStart: DateTime.now(),
            epochWallTime: false,
            monotonicOrigin: 98706000,
            build: const Duration(milliseconds: 250),
          ),
        ]);
        await client.flush();

        final Map<String, dynamic> view = transport.latestViews.single;
        for (final Map<String, dynamic> task in transport.eventsOf(
          'long_task',
        )) {
          expect(
            task['date']! as int,
            greaterThanOrEqualTo(view['date']! as int),
          );
          expect(
            task['date']! as int,
            lessThanOrEqualTo(DateTime.now().millisecondsSinceEpoch),
          );
          expect(
            at(task, 'long_task.start_time')! as int,
            greaterThanOrEqualTo(0),
          );
          expect(
            at(task, 'long_task.start_time')! as int,
            lessThanOrEqualTo(at(view, 'view.time_spent')! as int),
          );
        }
        expect(transport.eventsOf('long_task'), hasLength(2));
      },
    );

    test(
      'long tasks can be switched off without losing view metrics',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(
          transport,
          configure: (RumTransport t) =>
              testConfiguration(t, trackViewPerformance: true),
        );

        client.startView('/checkout');
        client.recordFrameTiming(
          syntheticFrame(
            vsyncStart: DateTime.now(),
            build: const Duration(milliseconds: 200),
          ),
        );
        await client.flush();

        expect(transport.eventsOf('long_task'), isEmpty);
        expect(
          at(transport.latestViews.single, 'view.flutter_build_time.max'),
          200000000,
        );
      },
    );

    testWidgets(
      'the first frame of the app is a cold start with its time to display',
      (WidgetTester tester) async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(
          transport,
          configure: (RumTransport t) =>
              testConfiguration(t, trackViewPerformance: true),
        );
        try {
          await tester.pumpWidget(const SizedBox());
          client.startView('/home');
          await tester.pump();
          await tester.pump();
          await client.flush();

          final Map<String, dynamic> vital = transport.eventsOf('vital').single;
          expect(at(vital, 'vital.type'), 'app_launch');
          expect(at(vital, 'vital.app_launch_metric'), 'ttid');
          expect(at(vital, 'vital.startup_type'), 'cold_start');
          expect(at(vital, 'vital.is_prewarmed'), isFalse);
          final int ttid = at(vital, 'vital.duration')! as int;
          expect(ttid, inInclusiveRange(0, 60000000000));
          final Map<String, dynamic> start = transport
              .eventsOf('action')
              .single;
          expect(at(start, 'action.type'), 'application_start');
          expect(at(start, 'action.loading_time'), ttid);
          expect(start['date'], vital['date'], reason: 'it began with the SDK');
        } finally {
          await client.stop();
        }
      },
    );

    testWidgets(
      'startup and first build are not measured when view performance is off',
      (WidgetTester tester) async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(transport);
        try {
          await tester.pumpWidget(const SizedBox());
          client.startView('/home');
          await tester.pump();
          await client.flush();

          expect(transport.eventsOf('vital'), isEmpty);
          expect(transport.eventsOf('action'), isEmpty);
          expect(at(transport.latestViews.single, 'view.performance'), isNull);
        } finally {
          await client.stop();
        }
      },
    );

    testWidgets(
      'the first build of each view is the end of the first frame built for it',
      (WidgetTester tester) async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(
          transport,
          configure: (RumTransport t) =>
              testConfiguration(t, trackViewPerformance: true),
        );
        Map<String, dynamic> view(String url) => transport.latestViews
            .singleWhere((Map<String, dynamic> v) => at(v, 'view.url') == url);
        try {
          await tester.pumpWidget(const SizedBox());
          await tester.pump();

          client.startView('/a');
          await tester.pump();
          await client.flush();
          final int first =
              at(view('/a'), 'view.performance.fbc.timestamp')! as int;
          expect(first, inInclusiveRange(0, 60000000000));

          await tester.pump(const Duration(seconds: 1));
          await client.flush();
          expect(
            at(view('/a'), 'view.performance.fbc.timestamp'),
            first,
            reason: 'only the first frame counts',
          );

          client.startView('/b');
          await tester.pump();
          await client.flush();
          expect(
            at(view('/b'), 'view.performance.fbc.timestamp'),
            isA<int>(),
            reason: 'each view has its own',
          );
        } finally {
          await client.stop();
        }
      },
    );

    test('a duration vital measures between its start and stop', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(transport);

      client.startView('/checkout');
      client.startDurationVital(
        'checkout_form_ready',
        description: 'form rendered',
        context: const <String, Object?>{'step': 'payment'},
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));
      client.stopDurationVital('checkout_form_ready');
      client.stopDurationVital('never_started');
      client.addDurationVital('cart_sync', const Duration(milliseconds: 640));
      await client.flush();

      final List<Map<String, dynamic>> vitals = transport.eventsOf('vital');
      expect(vitals, hasLength(2));
      expect(at(vitals[0], 'vital.type'), 'duration');
      expect(at(vitals[0], 'vital.name'), 'checkout_form_ready');
      expect(at(vitals[0], 'vital.description'), 'form rendered');
      expect(
        at(vitals[0], 'vital.duration')! as int,
        greaterThanOrEqualTo(25000000),
      );
      expect(at(vitals[0], 'context.step'), 'payment');
      expect(at(vitals[1], 'vital.name'), 'cart_sync');
      expect(at(vitals[1], 'vital.duration'), 640000000);
    });
  });

  group('context', () {
    test(
      'every event carries the application, identity and device context',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(
          transport,
          configure: (RumTransport t) => testConfiguration(
            t,
            buildVersion: '4',
            trackAnonymousUser: true,
            globalContext: const <String, Object?>{'region': 'ap-southeast-1'},
            deviceInfoProvider: FakeDeviceInfoProvider(
              const RumDeviceInfo(
                osName: 'Android',
                osVersion: '15',
                osBuild: 'AP3A.241005.015',
                deviceType: 'mobile',
                brand: 'Google',
                model: 'Pixel 8',
                batteryLevel: 0.62,
                powerSavingMode: false,
                isLowRam: false,
                totalRam: 8589934592,
                connectivityStatus: 'connected',
                connectivityInterfaces: <String>['wifi'],
              ),
            ),
          ),
        );

        client.setUser(
          const RumUser(
            id: 'user-42',
            name: 'Ada',
            email: 'ada@example.com',
            attributes: <String, Object?>{'plan': 'pro'},
          ),
        );
        client.setAccount(const RumAccount(id: 'acme', name: 'Acme'));
        client.addFeatureFlagEvaluation('new_checkout', true);
        client.startView('/checkout');
        client.addAction('Pay');
        await client.flush();

        final Map<String, dynamic> action = transport.eventsOf('action').single;
        expect(action['source'], 'flutter');
        expect(at(action, 'application.id'), 'checkout-mobile');
        expect(action['service'], 'checkout-app');
        expect(action['env'], 'production');
        expect(action['version'], '1.2.3+4');
        expect(action['build_version'], '4');
        expect(action['build_id'], 'build-android-arm64-42');
        expect(at(action, 'session.id'), matches(RegExp(r'^[0-9a-f-]{36}$')));
        expect(at(action, 'session.type'), 'user');
        expect(at(action, 'session.start'), isA<int>());
        expect(
          at(action, 'session.start'),
          at(transport.latestViews.single, 'session.start'),
        );
        expect(at(action, 'view.in_foreground'), isTrue);
        expect(at(action, 'usr.id'), 'user-42');
        expect(at(action, 'usr.name'), 'Ada');
        expect(at(action, 'usr.email'), 'ada@example.com');
        expect(at(action, 'usr.plan'), 'pro');
        expect(
          at(action, 'usr.anonymous_id'),
          matches(RegExp(r'^[0-9a-f-]{36}$')),
        );
        expect(at(action, 'account.id'), 'acme');
        expect(at(action, 'account.name'), 'Acme');
        expect(at(action, 'context.region'), 'ap-southeast-1');
        expect(at(action, 'feature_flags.new_checkout'), isTrue);
        expect(at(action, 'os.name'), 'Android');
        expect(at(action, 'os.version'), '15');
        expect(at(action, 'os.version_major'), '15');
        expect(at(action, 'os.build'), 'AP3A.241005.015');
        expect(at(action, 'device.type'), 'mobile');
        expect(at(action, 'device.brand'), 'Google');
        expect(at(action, 'device.model'), 'Pixel 8');
        expect(at(action, 'device.architecture'), 'arm64');
        expect(at(action, 'device.battery_level'), 0.62);
        expect(at(action, 'device.power_saving_mode'), isFalse);
        expect(at(action, 'device.is_low_ram'), isFalse);
        expect(at(action, 'device.total_ram'), 8589934592);
        expect(at(action, 'device.locale'), isA<String>());
        expect(
          at(action, 'device.time_zone'),
          matches(RegExp(r'^UTC[+-]\d{2}:\d{2}$')),
        );
        expect(at(action, 'connectivity.status'), 'connected');
        expect(at(action, 'connectivity.interfaces'), <Object?>['wifi']);
        expect(at(action, 'display.viewport.width'), isA<int>());
        expect(at(action, 'display.viewport.height'), isA<int>());
        expect(at(action, 'sdk.name'), 'molesignal_flutter');
        expect(at(action, 'sdk.version'), sdkVersion);
        expect(at(action, 'sdk.session_sample_rate'), 100);
        expect(at(action, 'sdk.replay_sample_rate'), 0);

        final Map<String, dynamic> view = transport.latestViews.single;
        expect(at(view, 'usr.id'), 'user-42');
        expect(at(view, 'feature_flags.new_checkout'), isTrue);
      },
    );

    test(
      'identity can be cleared and the event context is merged over the global one',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(
          transport,
          configure: (RumTransport t) => testConfiguration(
            t,
            user: const RumUser(id: 'user-1'),
            globalContext: const <String, Object?>{'a': 1, 'b': 2},
          ),
        );

        expect(client.getUser()!.id, 'user-1');
        client.clearUser();
        client.setAccount(const RumAccount(id: 'acme'));
        client.clearAccount();
        client.removeGlobalContextProperty('a');
        client.setGlobalContextProperty('c', 3);
        expect(client.getGlobalContext(), <String, Object?>{'b': 2, 'c': 3});
        client.addAction('Go', context: const <String, Object?>{'b': 'over'});
        await client.flush();

        final Map<String, dynamic> action = transport.eventsOf('action').single;
        expect(action.containsKey('usr'), isFalse);
        expect(action.containsKey('account'), isFalse);
        expect(at(action, 'context'), <String, Object?>{'b': 'over', 'c': 3});
        client.clearGlobalContext();
        expect(client.getGlobalContext(), isEmpty);
        expect(
          () => client.setUser(const RumUser(id: ' ')),
          throwsArgumentError,
        );
        expect(
          () => client.setAccount(const RumAccount(id: '')),
          throwsArgumentError,
        );
      },
    );

    test('device info is optional and never blocks an event', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(transport);

      client.addAction('Plain');
      await client.flush();

      final Map<String, dynamic> action = transport.eventsOf('action').single;
      expect(action.containsKey('connectivity'), isFalse);
      expect(at(action, 'device.brand'), isNull);
      expect(at(action, 'device.type'), anyOf('mobile', 'tablet', 'desktop'));
      expect(at(action, 'os.name'), isA<String>());
    });

    test('internal context identifies the session, view and build', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(transport);

      client.startView('/checkout');
      await client.flush();

      final RumInternalContext context = client.getInternalContext();
      expect(context.applicationId, 'checkout-mobile');
      expect(context.sessionId, at(transport.latestViews.single, 'session.id'));
      expect(context.viewId, at(transport.latestViews.single, 'view.id'));
      expect(context.buildId, 'build-android-arm64-42');
      expect(context.toJson()['env'], 'production');
    });
  });

  group('session.start', () {
    test(
      'is the same on every event of a session and is when it began',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final int before = DateTime.now().millisecondsSinceEpoch;
        final MoleSignalRumClient client = await startClient(
          transport,
          configure: (RumTransport t) => testConfiguration(
            t,
            trackLongTasks: true,
            trackUserInteractions: true,
          ),
        );

        client.startView('/checkout');
        client.addAction('Pay');
        client.addError(StateError('declined'));
        client.startResource(
          'r',
          'GET',
          Uri.parse('https://api.example.test/'),
        );
        client.stopResource('r', statusCode: 200);
        client.addDurationVital('sync', const Duration(milliseconds: 5));
        client.recordFrameTiming(
          syntheticFrame(
            vsyncStart: DateTime.now(),
            build: const Duration(milliseconds: 150),
          ),
        );
        await client.flush();

        final int start =
            client.sessionManager.active().startedAtMicros ~/ 1000;
        final Set<Object?> types = <Object?>{};
        for (final Map<String, dynamic> event in transport.events) {
          types.add(event['type']);
          expect(at(event, 'session.start'), start, reason: '${event['type']}');
          expect(at(event, 'session.start'), isA<int>());
        }
        expect(
          types,
          containsAll(<String>[
            'view',
            'action',
            'error',
            'resource',
            'long_task',
            'vital',
          ]),
        );
        expect(start, greaterThanOrEqualTo(before));
        expect(start, lessThanOrEqualTo(DateTime.now().millisecondsSinceEpoch));
      },
    );

    test(
      'is the original start when the app resumes a session after a restart',
      () async {
        final MemoryRumPersistence persistence = MemoryRumPersistence();
        final RecordingTransport first = RecordingTransport();
        final MoleSignalRumClient one = await MoleSignalRumClient.create(
          testConfiguration(first, persistence: persistence),
        );
        one.startView('/a');
        await one.stop();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final RecordingTransport second = RecordingTransport();
        final MoleSignalRumClient two = await MoleSignalRumClient.create(
          testConfiguration(second, persistence: persistence),
        );
        two.startView('/b');
        await two.stop();

        final Map<String, dynamic> firstView = first.latestViews.single;
        final Map<String, dynamic> secondView = second.latestViews.single;
        expect(at(secondView, 'session.id'), at(firstView, 'session.id'));
        expect(at(secondView, 'session.start'), at(firstView, 'session.start'));
        expect(
          secondView['date']! as int,
          greaterThan(at(secondView, 'session.start')! as int),
          reason: 'the second launch is later than the session it joined',
        );
      },
    );

    test(
      'a new session begins when the SDK starts, not after its first event',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(transport);
        await Future<void>.delayed(const Duration(milliseconds: 30));

        client.startView('/a');
        await client.flush();

        final Map<String, dynamic> view = transport.latestViews.single;
        expect(
          (view['date']! as int) - (at(view, 'session.start')! as int),
          greaterThanOrEqualTo(25),
        );
      },
    );

    testWidgets('never comes after the application start it belongs to', (
      WidgetTester tester,
    ) async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(
        transport,
        configure: (RumTransport t) =>
            testConfiguration(t, trackViewPerformance: true),
      );
      try {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        await client.flush();

        final Map<String, dynamic> start = transport.eventsOf('action').single;
        expect(at(start, 'action.type'), 'application_start');
        expect(
          start['date']! as int,
          greaterThanOrEqualTo(at(start, 'session.start')! as int),
        );
      } finally {
        await client.stop();
      }
    });
  });

  group('wire format', () {
    test(
      'all integer fields are integers and no session events are sent',
      () async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await startClient(
          transport,
          configure: (RumTransport t) => testConfiguration(
            t,
            trackUserInteractions: true,
            trackLongTasks: true,
            trackViewPerformance: true,
          ),
        );

        client.startView('/checkout');
        client.recordFrameTiming(
          syntheticFrame(
            vsyncStart: DateTime.now(),
            build: const Duration(milliseconds: 150),
          ),
        );
        client.recordTap(
          name: 'Tap',
          position: const Offset(1, 2),
          explicit: false,
        );
        client.startResource(
          'r',
          'GET',
          Uri.parse('https://api.example.test/'),
        );
        client.stopResource('r', statusCode: 200, size: 5);
        client.addError(StateError('boom'));
        client.addDurationVital('v', const Duration(milliseconds: 5));
        client.addTiming('t');
        await client.flush();

        const Set<String> fractional = <String>{
          'refresh_rate_average',
          'refresh_rate_min',
          'slow_frames_rate',
          'freeze_rate',
          'battery_level',
          'session_sample_rate',
          'replay_sample_rate',
        };
        void visit(Object? value, String key) {
          if (value is Map<dynamic, dynamic>) {
            value.forEach((dynamic k, dynamic v) => visit(v, k as String));
          } else if (value is List<dynamic>) {
            for (final dynamic item in value) {
              visit(item, key);
            }
          } else if (value is double) {
            expect(
              fractional,
              contains(key),
              reason: '$key is a fractional number on the wire',
            );
          }
        }

        for (final Map<String, dynamic> event in transport.events) {
          visit(event, 'event');
          expect(event['type'], isNot('session'));
        }
        expect(
          transport.events.map((Map<String, dynamic> e) => e['type']).toSet(),
          containsAll(<String>[
            'view',
            'action',
            'error',
            'resource',
            'long_task',
            'vital',
          ]),
        );
      },
    );

    test('events are batched into one JSON array per upload', () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await startClient(transport);

      client.startView('/a');
      client.addAction('One');
      client.addAction('Two');
      await client.flush();

      expect(transport.eventRequests, hasLength(1));
      final RumTransportRequest request = transport.eventRequests.single;
      expect(
        request.url.toString(),
        'https://rum.example.test/api/v1/rum/events',
      );
      expect(request.headers['authorization'], 'Bearer $testClientToken');
      expect(request.headers['content-type'], 'application/json');
      expect(jsonDecode(request.body), isA<List<dynamic>>());
      expect(request.kind, RumUploadKind.events);
    });
  });
}

const String _aotStack = '''
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
pid: 6339, tid: 6366, name 1.ui
os: android arch: arm64 comp: yes sim: no
build_id: '5d3b4e0a1fe4a0c7a5f3d6e2b1c0a9f8'
isolate_dso_base: 78e1d9500000, vm_dso_base: 78e1d9500000
isolate_instructions: 78e1d5d000, vm_instructions: 78e1d58000
    #00 abs 000078e1d9a7b9bf virt 000000000057b9bf _kDartIsolateSnapshotInstructions+0x35a1b
    #01 abs 000078e1d9a7bb2f virt 000000000057bb2f _kDartIsolateSnapshotInstructions+0x35b2f
''';
