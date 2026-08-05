import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../configuration.dart';
import 'sink.dart';

final class FlutterRumInstrumentation with WidgetsBindingObserver {
  FlutterRumInstrumentation(this._configuration, this._sink);

  final NormalizedRumConfiguration _configuration;
  final RumInstrumentationSink _sink;

  FlutterExceptionHandler? _previousFlutterError;
  bool Function(Object, StackTrace)? _previousPlatformError;
  FlutterExceptionHandler? _flutterHandler;
  bool Function(Object, StackTrace)? _platformHandler;
  bool _observingLifecycle = false;
  bool _observingTimings = false;

  void start() {
    final WidgetsBinding binding = WidgetsBinding.instance;
    if (_configuration.trackFlutterErrors) _installFlutterErrors();
    if (_configuration.trackPlatformErrors) _installPlatformErrors(binding);
    if (_configuration.trackAppLifecycle) {
      binding.addObserver(this);
      _observingLifecycle = true;
    }
    if (_configuration.trackLongFrames || _configuration.trackViewPerformance) {
      binding.addTimingsCallback(_onTimings);
      _observingTimings = true;
    }
  }

  void stop() {
    final WidgetsBinding binding = WidgetsBinding.instance;
    if (_observingLifecycle) binding.removeObserver(this);
    if (_observingTimings) binding.removeTimingsCallback(_onTimings);
    _observingLifecycle = false;
    _observingTimings = false;

    if (_flutterHandler != null && FlutterError.onError == _flutterHandler) {
      FlutterError.onError = _previousFlutterError;
    }
    if (_platformHandler != null &&
        identical(binding.platformDispatcher.onError, _platformHandler)) {
      binding.platformDispatcher.onError = _previousPlatformError;
    }
    _flutterHandler = null;
    _platformHandler = null;
  }

  void _installFlutterErrors() {
    _previousFlutterError = FlutterError.onError;
    void handler(FlutterErrorDetails details) {
      _sink.recordCapturedError(
        details.exception,
        stackTrace: details.stack,
        context: <String, Object?>{
          if (details.library != null) 'library': details.library,
          if (details.context != null)
            'diagnostics_context': details.context.toString(),
          'silent': details.silent,
        },
        source: 'flutter',
      );
      final FlutterExceptionHandler? previous = _previousFlutterError;
      if (previous != null) {
        previous(details);
      } else {
        FlutterError.presentError(details);
      }
    }

    _flutterHandler = handler;
    FlutterError.onError = handler;
  }

  void _installPlatformErrors(WidgetsBinding binding) {
    _previousPlatformError = binding.platformDispatcher.onError;
    bool handler(Object error, StackTrace stackTrace) {
      _sink.recordCapturedError(
        error,
        stackTrace: stackTrace,
        context: const <String, Object?>{},
        source: 'platform',
      );
      return _previousPlatformError?.call(error, stackTrace) ?? false;
    }

    _platformHandler = handler;
    binding.platformDispatcher.onError = handler;
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final FrameTiming timing in timings) {
      _sink.recordFrameTiming(timing);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _sink.handleLifecycleState(state);
  }
}
