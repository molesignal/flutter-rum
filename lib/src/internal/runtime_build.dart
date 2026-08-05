import 'package:flutter/foundation.dart';

import 'runtime_build_stub.dart'
    if (dart.library.io) 'runtime_build_io.dart'
    as runtime;

String detectRumPlatform() {
  if (kIsWeb) return 'flutter';
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    _ => 'flutter',
  };
}

String detectRumArchitecture() {
  if (kIsWeb) {
    return const bool.fromEnvironment('dart.library.wasm')
        ? 'wasm32'
        : 'javascript';
  }
  return normalizeRumArchitecture(runtime.runtimeArchitecture());
}

String normalizeRumArchitecture(String value) {
  final String normalized = value.trim().toLowerCase().replaceAll('_', '-');
  return switch (normalized) {
    'aarch64' || 'arm64-v8a' || 'arm64' => 'arm64',
    'armeabi-v7a' || 'armv7' || 'arm' => 'armv7',
    'amd64' || 'x64' || 'x86-64' || 'x86_64' => 'x86_64',
    'i386' || 'i686' || 'x86' => 'x86',
    'js' || 'javascript' => 'javascript',
    'wasm' || 'wasm32' => 'wasm32',
    '' => 'unknown',
    _ => normalized,
  };
}
