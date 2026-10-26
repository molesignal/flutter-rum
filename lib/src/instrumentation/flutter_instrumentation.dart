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
  bool _observing = false;
  bool _observingTimings = false;

  void start() {
    final WidgetsBinding binding = WidgetsBinding.instance;
    if (_configuration.trackFlutterErrors) _installFlutterErrors();
    if (_configuration.trackPlatformErrors) _installPlatformErrors();
    if (_configuration.trackAppLifecycle ||
        _configuration.trackUserInteractions) {
      binding.addObserver(this);
      _observing = true;
    }
    if (_configuration.trackLongTasks || _configuration.trackViewPerformance) {
      binding.addTimingsCallback(_onTimings);
      _observingTimings = true;
    }
  }

  void stop() {
    final WidgetsBinding binding = WidgetsBinding.instance;
    if (_observing) binding.removeObserver(this);
    if (_observingTimings) binding.removeTimingsCallback(_onTimings);
    _observing = false;
    _observingTimings = false;

    if (_flutterHandler != null && FlutterError.onError == _flutterHandler) {
      FlutterError.onError = _previousFlutterError;
    }
    if (_platformHandler != null &&
        identical(PlatformDispatcher.instance.onError, _platformHandler)) {
      PlatformDispatcher.instance.onError = _previousPlatformError;
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
        meta: <String, Object?>{
          if (details.library != null) 'library': details.library,
          if (details.context != null)
            'diagnostics_context': details.context.toString(),
        },
        fatal: false,
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

  void _installPlatformErrors() {
    _previousPlatformError = PlatformDispatcher.instance.onError;
    bool handler(Object error, StackTrace stackTrace) {
      _sink.recordCapturedError(error, stackTrace: stackTrace, fatal: true);
      return _previousPlatformError?.call(error, stackTrace) ?? false;
    }

    _platformHandler = handler;
    PlatformDispatcher.instance.onError = handler;
  }

  void _onTimings(List<FrameTiming> timings) {
    _sink.recordFrameTimings(timings);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_configuration.trackAppLifecycle) _sink.handleLifecycleState(state);
  }

  /// Observes the system back button without handling it, so the navigator
  /// still pops its route.
  @override
  Future<bool> didPopRoute() async {
    _sink.recordBack();
    return false;
  }
}
