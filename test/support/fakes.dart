import 'dart:ui';

import 'package:molesignal_flutter/molesignal_flutter.dart';

/// A device-info provider with a fixed snapshot.
final class FakeDeviceInfoProvider implements RumDeviceInfoProvider {
  FakeDeviceInfoProvider(this.current);

  @override
  RumDeviceInfo current;

  int refreshes = 0;
  bool closed = false;

  @override
  Future<void> refresh() async {
    refreshes += 1;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// A frame that began at [vsyncStart] on the wall clock.
///
/// Flutter's phase timestamps come from a monotonic clock of unknown origin;
/// only `rasterFinishWallTime` is wall time, as in the real engine.
///
/// With [epochWallTime] false the frame carries its monotonic raster finish as
/// `rasterFinishWallTime`, as the Flutter Web engine does; [vsyncStart] is then
/// only the moment on the monotonic clock `monotonicOrigin` stands for.
FrameTiming syntheticFrame({
  required DateTime vsyncStart,
  Duration vsyncOverhead = const Duration(milliseconds: 1),
  Duration build = const Duration(milliseconds: 4),
  Duration raster = const Duration(milliseconds: 4),
  bool epochWallTime = true,
  int monotonicOrigin = 5000000000,
}) {
  final int origin = monotonicOrigin;
  final int buildStart = origin + vsyncOverhead.inMicroseconds;
  final int buildFinish = buildStart + build.inMicroseconds;
  final int rasterFinish = buildFinish + raster.inMicroseconds;
  return FrameTiming(
    vsyncStart: origin,
    buildStart: buildStart,
    buildFinish: buildFinish,
    rasterStart: buildFinish,
    rasterFinish: rasterFinish,
    rasterFinishWallTime: epochWallTime
        ? vsyncStart.microsecondsSinceEpoch + (rasterFinish - origin)
        : rasterFinish,
  );
}
