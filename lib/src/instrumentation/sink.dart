import 'package:flutter/scheduler.dart';

import '../models.dart';

abstract interface class RumInstrumentationSink {
  void recordCapturedError(
    Object error, {
    StackTrace? stackTrace,
    RumContext context,
    required String source,
  });

  void recordFrameTiming(FrameTiming timing);

  void handleLifecycleState(AppLifecycleState state);
}
