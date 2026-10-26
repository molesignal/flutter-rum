import 'dart:math';
import 'dart:ui' show FrameTiming;

import '../internal/units.dart';
import '../models.dart';

/// Streaming minimum, maximum and average of one duration series, in whole
/// nanoseconds.
final class DurationStats {
  int _count = 0;
  int _sum = 0;
  int _minimum = 0;
  int _maximum = 0;

  void add(int nanoseconds) {
    if (_count == 0 || nanoseconds < _minimum) _minimum = nanoseconds;
    if (_count == 0 || nanoseconds > _maximum) _maximum = nanoseconds;
    _sum += nanoseconds;
    _count += 1;
  }

  /// `{min, max, average}` for the contract's `perfMetric`, or `null` when
  /// nothing was recorded.
  RumContext? toJson() => _count == 0
      ? null
      : <String, Object?>{
          'min': _minimum,
          'max': _maximum,
          'average': (_sum / _count).round(),
        };
}

/// Rendering metrics of one view, accumulated from Flutter's frame timings.
///
/// A frame is *slow* when producing it took longer than the display's frame
/// budget and *frozen* when it took at least the frozen threshold.
final class FrameStats {
  final DurationStats build = DurationStats();
  final DurationStats raster = DurationStats();
  int frames = 0;
  double _refreshRateSum = 0;
  double? _refreshRateMinimum;
  int _slowNanoseconds = 0;
  int _frozenNanoseconds = 0;

  void add(
    FrameTiming timing, {
    required double displayRefreshRate,
    required Duration frozenThreshold,
  }) {
    final int spanMicroseconds = timing.totalSpan.inMicroseconds;
    build.add(nanosecondsOf(timing.buildDuration));
    raster.add(nanosecondsOf(timing.rasterDuration));
    frames += 1;

    // The rate this frame could sustain, capped by what the display shows.
    final double rate = spanMicroseconds <= 0
        ? displayRefreshRate
        : min(displayRefreshRate, 1000000 / spanMicroseconds);
    _refreshRateSum += rate;
    final double? lowest = _refreshRateMinimum;
    _refreshRateMinimum = lowest == null ? rate : min(lowest, rate);

    if (spanMicroseconds >= frozenThreshold.inMicroseconds) {
      _frozenNanoseconds += spanMicroseconds * 1000;
    } else {
      final double budgetMicroseconds = 1000000 / displayRefreshRate;
      if (spanMicroseconds > budgetMicroseconds) {
        _slowNanoseconds += ((spanMicroseconds - budgetMicroseconds) * 1000)
            .round();
      }
    }
  }

  double? get refreshRateAverage =>
      frames == 0 ? null : _round(_refreshRateSum / frames);

  double? get refreshRateMinimum =>
      _refreshRateMinimum == null ? null : _round(_refreshRateMinimum!);

  /// Milliseconds spent in slow frames per second of view time.
  double? slowFramesRate(Duration timeSpent) {
    if (frames == 0 || timeSpent <= Duration.zero) return null;
    return _round(
      (_slowNanoseconds / 1000000) / (timeSpent.inMicroseconds / 1000000),
    );
  }

  /// Seconds spent in frozen frames per hour of view time.
  double? freezeRate(Duration timeSpent) {
    if (frames == 0 || timeSpent <= Duration.zero) return null;
    return _round(
      (_frozenNanoseconds / 1000000000) /
          (timeSpent.inMicroseconds / 3600000000),
    );
  }
}

double _round(double value) => (value * 100).roundToDouble() / 100;
