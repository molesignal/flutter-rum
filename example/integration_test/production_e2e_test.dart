import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('release build uploads Dart and forwarded native failures', (
    WidgetTester tester,
  ) async {
    const String application = String.fromEnvironment(
      'MOLESIGNAL_APPLICATION_ID',
    );
    const String token = String.fromEnvironment('MOLESIGNAL_RUM_TOKEN');
    const String site = String.fromEnvironment('MOLESIGNAL_SITE');
    const String service = String.fromEnvironment('MOLESIGNAL_SERVICE');
    const String version = String.fromEnvironment('MOLESIGNAL_VERSION');
    const String architecture = String.fromEnvironment(
      'MOLESIGNAL_ARCHITECTURE',
    );
    const String debugId = String.fromEnvironment('MOLESIGNAL_DEBUG_ID');
    const String nativeKind = String.fromEnvironment(
      'MOLESIGNAL_NATIVE_ARTIFACT_KIND',
    );
    const String nativeModule = String.fromEnvironment(
      'MOLESIGNAL_NATIVE_MODULE',
    );
    const String nativeRelativeAddress = String.fromEnvironment(
      'MOLESIGNAL_NATIVE_RELATIVE_ADDRESS',
    );

    expect(application, isNotEmpty, reason: 'missing application ID define');
    expect(token, isNotEmpty, reason: 'missing RUM token define');
    expect(site, isNotEmpty, reason: 'missing receiver site define');
    expect(service, isNotEmpty, reason: 'missing service define');
    expect(version, isNotEmpty, reason: 'missing version define');
    expect(architecture, isNotEmpty, reason: 'missing architecture define');
    expect(debugId, isNotEmpty, reason: 'missing debug ID define');

    final MoleSignalRumClient rum = await initRum(
      const RumConfiguration(
        applicationId: application,
        clientToken: token,
        site: site,
        service: service,
        env: 'production-e2e',
        version: version,
        architecture: architecture,
        debugId: debugId,
        sessionSampleRate: 100,
        sessionReplaySampleRate: 0,
        trackUserInteractions: false,
        trackAnonymousUser: false,
      ),
    );
    rum.startView('Production E2E', path: '/production-e2e');

    try {
      _throwDartReleaseFailure();
    } on Object catch (error, stackTrace) {
      rum.addError(
        error,
        stackTrace: stackTrace,
        context: const <String, Object?>{
          'e2e_marker': 'flutter-release-dart-failure',
        },
      );
    }

    if (nativeKind.isNotEmpty &&
        nativeModule.isNotEmpty &&
        nativeRelativeAddress.isNotEmpty) {
      rum.addError(
        StateError('forwarded native production failure'),
        frames: <RumStackFrame>[
          RumStackFrame(
            artifactKind: _artifactKind(nativeKind),
            module: nativeModule,
            relativeAddress: nativeRelativeAddress,
            debugId: debugId,
          ),
        ],
        context: const <String, Object?>{
          'e2e_marker': 'flutter-release-native-failure',
        },
      );
    }

    final RumFlushResult result = await rum.stop();
    expect(result.timedOut, isFalse);
    expect(result.dropped, 0);
    expect(result.remaining, 0);
  });
}

Never _throwDartReleaseFailure() {
  throw StateError('flutter release symbolication marker');
}

RumArtifactKind _artifactKind(String value) => switch (value) {
  'android_native_symbols' => RumArtifactKind.androidNativeSymbols,
  'apple_dsym' => RumArtifactKind.appleDsym,
  _ => throw ArgumentError.value(
    value,
    'MOLESIGNAL_NATIVE_ARTIFACT_KIND',
    'must be android_native_symbols or apple_dsym',
  ),
};
