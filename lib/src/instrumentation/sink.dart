import 'package:flutter/scheduler.dart';

import '../models.dart';

abstract interface class RumInstrumentationSink {
  /// An error the Flutter framework or the platform dispatcher caught. A
  /// [fatal] error is an uncaught one that reached the root and counts as a
  /// crash.
  void recordCapturedError(
    Object error, {
    StackTrace? stackTrace,
    RumContext meta,
    required bool fatal,
  });

  /// Frame timings the engine reported, oldest first.
  void recordFrameTimings(List<FrameTiming> timings);

  void handleLifecycleState(AppLifecycleState state);

  /// The system back button or gesture was used.
  void recordBack();
}
