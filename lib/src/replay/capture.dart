import 'dart:ui';

import '../models.dart';

typedef RumReplayEmit = void Function(String sessionId, RumContext event);

/// Internal bridge implemented by the widget that owns the replay boundary.
abstract interface class RumReplayCapture {
  void start(String sessionId, RumReplayEmit emit);

  void stop();

  void requestCapture();

  void recordPointer(Offset position, {int? timestampMilliseconds});
}
