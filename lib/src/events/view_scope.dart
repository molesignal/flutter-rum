import '../internal/identifiers.dart';
import '../internal/units.dart';
import '../models.dart';
import '../session/session_manager.dart';
import 'frame_stats.dart';

const int _maximumCustomTimings = 50;

/// One screen the user has been looking at, from `startView` to the next view,
/// the app going to the background, or `stopView`.
///
/// A view is reported again whenever something in it changed. Each report
/// carries the next [revision] and the counts so far; `date` stays the start
/// of the view.
final class ViewScope {
  ViewScope({
    required this.key,
    required this.name,
    required this.url,
    required this.session,
    required this.loadingType,
    this.context = const <String, Object?>{},
  }) : id = generateUuid(),
       startedAtMicros = nowMicros();

  final String id;

  /// What `startView` was called with; used to show the same screen again.
  final String key;
  final String name;
  final String url;
  final RumSession session;
  final String loadingType;

  /// Attributes passed to `startView`; they ride on this view's events.
  final RumContext context;
  final int startedAtMicros;
  final Stopwatch _clock = Stopwatch()..start();

  int revision = 0;
  bool active = true;

  /// Something changed since the last report.
  bool dirty = true;
  int actionCount = 0;
  int errorCount = 0;
  int crashCount = 0;
  int resourceCount = 0;
  int longTaskCount = 0;
  int frozenFrameCount = 0;
  int frustrationCount = 0;
  final Map<String, int> customTimings = <String, int>{};
  final FrameStats frames = FrameStats();

  /// Nanoseconds from the start of the view to the end of its first build.
  int? firstBuildNanoseconds;
  int _memorySum = 0;
  int _memorySamples = 0;
  int _memoryMaximum = 0;

  int get startedAtMillis => startedAtMicros ~/ 1000;

  Duration get timeSpent => _clock.elapsed;

  /// Nanoseconds since the view started.
  int get elapsedNanoseconds =>
      nanosecondsOfMicroseconds(_clock.elapsedMicroseconds);

  void stop() {
    if (!active) return;
    active = false;
    _clock.stop();
    dirty = true;
  }

  /// Records a custom timing now. Returns `false` when it cannot be kept.
  bool addTiming(String name) {
    final String key = timingKey(name);
    if (key.isEmpty) return false;
    if (!customTimings.containsKey(key) &&
        customTimings.length >= _maximumCustomTimings) {
      return false;
    }
    customTimings[key] = elapsedNanoseconds;
    dirty = true;
    return true;
  }

  void sampleMemory(int bytes) {
    if (bytes <= 0) return;
    _memorySum += bytes;
    _memorySamples += 1;
    if (bytes > _memoryMaximum) _memoryMaximum = bytes;
    dirty = true;
  }

  /// The contract's `view` body for the next revision.
  RumContext report() {
    revision += 1;
    dirty = false;
    final Duration spent = timeSpent;
    final RumContext? buildTime = frames.build.toJson();
    final RumContext? rasterTime = frames.raster.toJson();
    final double? refreshAverage = frames.refreshRateAverage;
    final double? refreshMinimum = frames.refreshRateMinimum;
    final double? slowRate = frames.slowFramesRate(spent);
    final double? freezeRate = frames.freezeRate(spent);
    return <String, Object?>{
      'id': id,
      'url': url,
      'name': name,
      'revision': revision,
      'time_spent': nanosecondsOf(spent),
      'is_active': active,
      'loading_type': loadingType,
      'action': <String, Object?>{'count': actionCount},
      'error': <String, Object?>{'count': errorCount},
      'crash': <String, Object?>{'count': crashCount},
      'resource': <String, Object?>{'count': resourceCount},
      'long_task': <String, Object?>{'count': longTaskCount},
      'frozen_frame': <String, Object?>{'count': frozenFrameCount},
      'frustration': <String, Object?>{'count': frustrationCount},
      if (customTimings.isNotEmpty)
        'custom_timings': Map<String, int>.of(customTimings),
      if (firstBuildNanoseconds != null)
        'performance': <String, Object?>{
          'fbc': <String, Object?>{'timestamp': firstBuildNanoseconds},
        },
      'flutter_build_time': ?buildTime,
      'flutter_raster_time': ?rasterTime,
      'refresh_rate_average': ?refreshAverage,
      'refresh_rate_min': ?refreshMinimum,
      'slow_frames_rate': ?slowRate,
      'freeze_rate': ?freezeRate,
      if (_memorySamples > 0)
        'memory_average': (_memorySum / _memorySamples).round(),
      if (_memorySamples > 0) 'memory_max': _memoryMaximum,
    };
  }
}

/// A `custom_timings` key: the contract allows `[A-Za-z0-9_.@$-]{1,128}`.
String timingKey(String name) {
  final String cleaned = name.trim().replaceAll(
    RegExp(r'[^A-Za-z0-9_.@$-]'),
    '_',
  );
  return cleaned.length <= 128 ? cleaned : cleaned.substring(0, 128);
}
