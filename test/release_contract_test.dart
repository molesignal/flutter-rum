import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';

import 'support/configuration.dart';
import 'support/recording_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'build identity and structured mobile frames use the symbolication contract',
    () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await MoleSignalRumClient.create(
        testConfiguration(
          transport,
          defaultPrivacyLevel: RumPrivacyLevel.allow,
        ),
      );
      client.startView('/checkout');
      client.addResource(
        RumResource(
          method: 'POST',
          url: Uri.parse('https://api.example.test/pay?token=secret'),
          duration: const Duration(microseconds: 12345),
          responseSize: 64,
          statusCode: 201,
        ),
      );
      client.addError(
        StateError(
          'failed with Authorization: Bearer $testClientToken at '
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
      await client.flush();
      await client.stop();

      for (final Map<String, dynamic> event in transport.events) {
        expect(at(event, 'application.id'), 'checkout-mobile');
        expect(event['service'], 'checkout-app');
        expect(event['version'], '1.2.3+4');
        expect(event['build_id'], 'build-android-arm64-42');
        expect(at(event, 'device.architecture'), 'arm64');
      }

      final Map<String, dynamic> error = transport.eventsOf('error').single;
      final String wire = jsonEncode(error);
      expect(wire, isNot(contains(testClientToken)));
      expect(wire, isNot(contains('/Users/alice')));
      expect(wire, isNot(contains('user:password')));
      expect(wire, isNot(contains('token=secret')));
      final List<Map<String, dynamic>> frames =
          (at(error, 'error.frames')! as List<dynamic>)
              .map(
                (dynamic frame) =>
                    Map<String, dynamic>.from(frame as Map<dynamic, dynamic>),
              )
              .toList(growable: false);
      expect(frames[0]['artifact_kind'], 'android_native_symbols');
      expect(frames[0]['module'], 'libpayments.so');
      expect(frames[0]['function'], 'payments_crash');
      expect(frames[0]['instruction_addr'], '0x1010');
      expect(frames[0]['image_addr'], '0x1000');
      expect(frames[0]['relative_address'], '0x10');
      expect(frames[0]['debug_id'], 'build-android-arm64-42');
      expect(frames[1]['file'], 'lib/checkout.dart');
      expect(frames[1]['line'], 8);
      expect(frames[1]['column'], 1);
      expect(at(error, 'error.stack'), isNot(contains('/Users/alice')));
      expect(at(error, 'error.stack'), contains('Checkout.pay'));

      final Map<String, dynamic> resource = transport
          .eventsOf('resource')
          .single;
      expect(at(resource, 'resource.url'), 'https://api.example.test/pay');
      expect(at(resource, 'resource.duration'), 12345000);
      expect(at(resource, 'resource.size'), 64);
      expect(at(resource, 'resource.status_code'), 201);
    },
  );

  test('a frame-specific build identity overrides the event one', () async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient client = await MoleSignalRumClient.create(
      testConfiguration(transport),
    );
    addTearDown(client.stop);
    client.addError(
      StateError('native'),
      frames: const <RumStackFrame>[
        RumStackFrame(
          artifactKind: RumArtifactKind.appleDsym,
          module: 'Runner',
          relativeAddress: '0x4d2',
          debugId: 'DSYM-UUID',
          buildId: 'abcdef',
        ),
      ],
    );
    await client.flush();

    final Map<String, dynamic> frame =
        (at(transport.eventsOf('error').single, 'error.frames')!
                    as List<dynamic>)
                .single
            as Map<String, dynamic>;
    expect(frame['debug_id'], 'DSYM-UUID');
    expect(frame['build_id'], 'abcdef');
    expect(frame['artifact_kind'], 'apple_dsym');
  });

  test(
    'raw stack text is only sent when the privacy level allows it',
    () async {
      Future<String?> stackOf(RumPrivacyLevel level) async {
        final RecordingTransport transport = RecordingTransport();
        final MoleSignalRumClient client = await MoleSignalRumClient.create(
          testConfiguration(transport, defaultPrivacyLevel: level),
        );
        client.addError(
          StateError('x'),
          stackTrace: StackTrace.fromString(
            'password=hunter2 and a line that is no frame\n'
            '#0 Cart.total (package:app/cart.dart:12:7)',
          ),
        );
        await client.stop();
        return at(transport.eventsOf('error').single, 'error.stack') as String?;
      }

      final String masked = (await stackOf(RumPrivacyLevel.mask))!;
      expect(masked, '    at Cart.total (package:app/cart.dart:12:7)');
      final String allowed = (await stackOf(RumPrivacyLevel.allow))!;
      expect(allowed, contains('a line that is no frame'));
      expect(allowed, contains('#0 Cart.total'));
    },
  );

  test(
    'credential format and local application binding fail clearly',
    () async {
      const String malformed = 'mspat-this-is-not-valid';
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
        contains('mspat-<36 lowercase alphanumeric>'),
      );
      expect(failure.toString(), isNot(contains(malformed)));

      final MemoryRumPersistence persistence = MemoryRumPersistence();
      final MoleSignalRumClient first = await MoleSignalRumClient.create(
        testConfiguration(
          RecordingTransport(),
          applicationId: 'app-a',
          persistence: persistence,
        ),
      );
      await first.stop();
      await expectLater(
        MoleSignalRumClient.create(
          testConfiguration(
            RecordingTransport(),
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

  test('the application id is validated like a contract identifier', () {
    for (final String id in <String>['has space', 'a' * 129, 'ünicode']) {
      expect(
        () => MoleSignalRumClient.create(
          testConfiguration(RecordingTransport(), applicationId: id),
        ),
        throwsArgumentError,
        reason: id,
      );
    }
  });

  test('diagnostics and persisted state never contain credentials', () async {
    final List<RumDiagnostic> diagnostics = <RumDiagnostic>[];
    final MemoryRumPersistence persistence = MemoryRumPersistence();
    final RecordingTransport throwing = RecordingTransport(
      respond: (RumTransportRequest request) => throw StateError(
        'Authorization: Bearer $testClientToken '
        'https://user:password@example.test/path?token=secret',
      ),
    );
    final MoleSignalRumClient client = await MoleSignalRumClient.create(
      testConfiguration(
        throwing,
        persistence: persistence,
        onError: diagnostics.add,
      ),
    );
    client.addAction(
      'failed $testClientToken',
      context: const <String, Object?>{
        'authorization': 'Bearer secret',
        'url': 'https://user:password@example.test/path?token=secret',
      },
    );
    await client.flush();
    await client.stop();

    final String diagnosticText = diagnostics
        .map((RumDiagnostic v) => '${v.message}|${v.cause}|${v.stackTrace}')
        .join('\n');
    expect(diagnosticText, isNotEmpty);
    expect(diagnosticText, isNot(contains(testClientToken)));
    expect(diagnosticText, isNot(contains('Bearer secret')));
    expect(diagnosticText, isNot(contains('user:password')));
    expect(diagnosticText, isNot(contains('token=secret')));
    final String persisted = persistence.values.values.join('\n');
    expect(persisted, isNot(contains(testClientToken)));
    expect(persisted, isNot(contains('Bearer secret')));
    expect(persisted, isNot(contains('user:password')));
    expect(persisted, isNot(contains('token=secret')));
  });

  test('resources with an impossible duration or size are dropped', () async {
    final List<RumDiagnostic> diagnostics = <RumDiagnostic>[];
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient client = await MoleSignalRumClient.create(
      testConfiguration(transport, onError: diagnostics.add),
    );
    addTearDown(client.stop);

    client.addResource(
      RumResource(
        method: 'GET',
        url: Uri.parse('https://api.example.test/a'),
        duration: const Duration(seconds: -1),
      ),
    );
    client.addResource(
      RumResource(
        method: 'GET',
        url: Uri.parse('https://api.example.test/b'),
        duration: Duration.zero,
        responseSize: -5,
      ),
    );
    await client.flush();

    expect(transport.eventsOf('resource'), isEmpty);
    expect(
      diagnostics.where(
        (RumDiagnostic d) =>
            d.message == 'RUM resource dropped: invalid duration or size',
      ),
      hasLength(2),
    );
  });

  test('every sensitive key is redacted wherever it appears', () async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient client = await MoleSignalRumClient.create(
      testConfiguration(
        transport,
        user: const RumUser(
          id: 'u1',
          attributes: <String, Object?>{'api_key': 'k', 'plan': 'pro'},
        ),
      ),
    );
    addTearDown(client.stop);

    client.setGlobalContextProperty('cookie', 'c');
    client.addAction(
      'Go',
      context: const <String, Object?>{
        'nested': <String, Object?>{'password': 'p', 'ok': 1},
      },
    );
    await client.flush();

    final Map<String, dynamic> action = transport.eventsOf('action').single;
    expect(at(action, 'usr.api_key'), '[Redacted]');
    expect(at(action, 'usr.plan'), 'pro');
    expect(at(action, 'context.cookie'), '[Redacted]');
    expect(at(action, 'context.nested.password'), '[Redacted]');
    expect(at(action, 'context.nested.ok'), 1);
  });

  test(
    'timing and feature flag names are not secrets, whatever they say',
    () async {
      final RecordingTransport transport = RecordingTransport();
      final MoleSignalRumClient client = await MoleSignalRumClient.create(
        testConfiguration(transport),
      );
      addTearDown(client.stop);

      client.startView('/account');
      client.addTiming('token_refreshed');
      client.addFeatureFlagEvaluation('new_password_flow', true);
      await client.flush();

      final Map<String, dynamic> view = transport.latestViews.single;
      expect(at(view, 'view.custom_timings.token_refreshed'), isA<int>());
      expect(at(view, 'feature_flags.new_password_flow'), isTrue);
    },
  );
}
