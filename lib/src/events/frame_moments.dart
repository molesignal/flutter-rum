import 'dart:math';
import 'dart:ui' as ui;

import '../internal/identifiers.dart';

/// A timestamp this far from now is not a wall clock reading.
const Duration _plausibleClockSkew = Duration(days: 1);

/// When a frame started, on the wall clock, in epoch microseconds.
///
/// Flutter stamps frame phases with a monotonic clock of unknown origin. The
/// end of rasterization additionally carries wall time on the mobile engines;
/// the start of the frame is placed on the wall clock relative to it. Where
/// that stamp is not an epoch time (Flutter Web reports its monotonic clock),
/// the newest frame of the delivered batch is taken to have finished when the
/// batch arrived, and the others are placed relative to it.
int frameStartMicros(
  ui.FrameTiming timing, {
  int? deliveredAtMicros,
  int? latestRasterFinish,
}) {
  final int now = deliveredAtMicros ?? nowMicros();
  final int rasterFinish = timing.timestampInMicroseconds(
    ui.FramePhase.rasterFinish,
  );
  final int wall = timing.timestampInMicroseconds(
    ui.FramePhase.rasterFinishWallTime,
  );
  final bool epoch = (wall - now).abs() < _plausibleClockSkew.inMicroseconds;
  final int rasterFinishWall = epoch
      ? wall
      : now - max(0, (latestRasterFinish ?? rasterFinish) - rasterFinish);
  return rasterFinishWall -
      (rasterFinish - timing.timestampInMicroseconds(ui.FramePhase.vsyncStart));
}
