import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/src/events/frame_moments.dart';
import 'package:molesignal_flutter/src/events/frame_stats.dart';
import 'package:molesignal_flutter/src/events/view_scope.dart';
import 'package:molesignal_flutter/src/session/session_manager.dart';

import 'support/fakes.dart';

FrameStats _stats(
  List<({int build, int raster})> frames, {
  double refreshRate = 60,
}) {
  final FrameStats stats = FrameStats();
  for (final ({int build, int raster}) frame in frames) {
    stats.add(
      syntheticFrame(
        vsyncStart: DateTime.now(),
        vsyncOverhead: Duration.zero,
        build: Duration(milliseconds: frame.build),
        raster: Duration(milliseconds: frame.raster),
      ),
      displayRefreshRate: refreshRate,
      frozenThreshold: const Duration(milliseconds: 700),
    );
  }
  return stats;
}

void main() {
  group('FrameStats', () {
    test(
      'build and raster time are minimum, maximum and average nanoseconds',
      () {
        final FrameStats stats = _stats(<({int build, int raster})>[
          (build: 2, raster: 4),
          (build: 4, raster: 5),
          (build: 9, raster: 3),
        ]);
        expect(stats.build.toJson(), <String, Object?>{
          'min': 2000000,
          'max': 9000000,
          'average': 5000000,
        });
        expect(stats.raster.toJson(), <String, Object?>{
          'min': 3000000,
          'max': 5000000,
          'average': 4000000,
        });
      },
    );

    test('an empty series has no summary', () {
      expect(FrameStats().build.toJson(), isNull);
      expect(FrameStats().refreshRateAverage, isNull);
      expect(FrameStats().slowFramesRate(const Duration(seconds: 1)), isNull);
      expect(FrameStats().freezeRate(const Duration(seconds: 1)), isNull);
    });

    test(
      'the refresh rate is what a frame could sustain, capped by the display',
      () {
        final FrameStats stats = _stats(<({int build, int raster})>[
          (build: 4, raster: 4), // 8 ms: faster than the display
          (build: 25, raster: 25), // 50 ms: 20 fps
        ]);
        expect(stats.refreshRateAverage, 40);
        expect(stats.refreshRateMinimum, 20);

        final FrameStats fast = _stats(<({int build, int raster})>[
          (build: 3, raster: 3),
        ], refreshRate: 120);
        expect(fast.refreshRateAverage, closeTo(120, 0.01));
      },
    );

    test(
      'slow frame time is what exceeds the frame budget, per second of view',
      () {
        // 60 Hz: a 16.67 ms budget. Two 26 ms frames are 9.33 ms over it each.
        final FrameStats stats = _stats(<({int build, int raster})>[
          (build: 10, raster: 16),
          (build: 10, raster: 16),
          (build: 3, raster: 3),
        ]);
        expect(
          stats.slowFramesRate(const Duration(seconds: 1)),
          closeTo(18.67, 0.01),
        );
        expect(
          stats.slowFramesRate(const Duration(seconds: 4)),
          closeTo(4.67, 0.01),
        );
        expect(stats.freezeRate(const Duration(seconds: 1)), 0);
      },
    );

    test('frozen frames count toward the freeze rate, in seconds per hour', () {
      final FrameStats stats = _stats(<({int build, int raster})>[
        (build: 400, raster: 400), // 800 ms: frozen
        (build: 3, raster: 3),
      ]);
      // 0.8 s frozen in 10 s of view = 288 s per hour; not also a slow frame.
      expect(stats.freezeRate(const Duration(seconds: 10)), closeTo(288, 0.1));
      expect(stats.slowFramesRate(const Duration(seconds: 10)), 0);
    });

    test('no view time means no rate', () {
      final FrameStats stats = _stats(<({int build, int raster})>[
        (build: 3, raster: 3),
      ]);
      expect(stats.slowFramesRate(Duration.zero), isNull);
      expect(stats.freezeRate(Duration.zero), isNull);
    });
  });

  group('frameStartMicros', () {
    test('uses the epoch stamp the engine gives', () {
      final DateTime start = DateTime.now().subtract(
        const Duration(seconds: 3),
      );
      expect(
        frameStartMicros(
          syntheticFrame(
            vsyncStart: start,
            vsyncOverhead: const Duration(milliseconds: 2),
            build: const Duration(milliseconds: 10),
            raster: const Duration(milliseconds: 6),
          ),
        ),
        start.microsecondsSinceEpoch,
      );
    });

    test(
      'places a frame relative to the delivery when the stamp is not an epoch',
      () {
        final int delivered = DateTime.now().microsecondsSinceEpoch;
        expect(
          frameStartMicros(
            syntheticFrame(
              vsyncStart: DateTime.now(),
              epochWallTime: false,
              monotonicOrigin: 8706000,
              build: const Duration(milliseconds: 10),
              raster: const Duration(milliseconds: 6),
            ),
            deliveredAtMicros: delivered,
          ),
          delivered - 17000,
          reason: 'it is taken to have finished at delivery; it took 17 ms',
        );
      },
    );

    test('places a batch relative to its newest frame', () {
      final int delivered = DateTime.now().microsecondsSinceEpoch;
      final FrameTiming older = syntheticFrame(
        vsyncStart: DateTime.now(),
        epochWallTime: false,
        monotonicOrigin: 1000000,
        vsyncOverhead: Duration.zero,
        build: const Duration(milliseconds: 5),
        raster: const Duration(milliseconds: 5),
      );
      final FrameTiming newer = syntheticFrame(
        vsyncStart: DateTime.now(),
        epochWallTime: false,
        monotonicOrigin: 1500000,
        vsyncOverhead: Duration.zero,
        build: const Duration(milliseconds: 5),
        raster: const Duration(milliseconds: 5),
      );
      final int latest = newer.timestampInMicroseconds(FramePhase.rasterFinish);
      expect(
        frameStartMicros(
          newer,
          deliveredAtMicros: delivered,
          latestRasterFinish: latest,
        ),
        delivered - 10000,
      );
      expect(
        frameStartMicros(
          older,
          deliveredAtMicros: delivered,
          latestRasterFinish: latest,
        ),
        delivered - 510000,
        reason: 'half a second before the newest frame ended, minus its 10 ms',
      );
    });

    test('treats a missing wall time like a foreign one', () {
      final int delivered = DateTime.now().microsecondsSinceEpoch;
      final FrameTiming frame = FrameTiming(
        vsyncStart: 100,
        buildStart: 200,
        buildFinish: 300,
        rasterStart: 400,
        rasterFinish: 500,
        rasterFinishWallTime: 0,
      );
      expect(
        frameStartMicros(frame, deliveredAtMicros: delivered),
        delivered - 400,
      );
    });
  });

  group('ViewScope', () {
    RumSession session() => RumSession(
      id: 'session-1',
      startedAtMicros: 1,
      lastActivityMicros: 1,
      sampled: true,
      replaySampled: false,
    );

    ViewScope scope() => ViewScope(
      key: '/a',
      name: 'A',
      url: '/a',
      session: session(),
      loadingType: 'view_controller_display',
    );

    test('each report is the next revision and clears the dirty flag', () {
      final ViewScope view = scope();
      expect(view.dirty, isTrue);
      expect(view.report()['revision'], 1);
      expect(view.dirty, isFalse);
      view.actionCount = 2;
      final Map<String, Object?> report = view.report();
      expect(report['revision'], 2);
      expect(report['action'], <String, Object?>{'count': 2});
    });

    test('time stops running when the view is stopped', () async {
      final ViewScope view = scope();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      view.stop();
      final Object? first = view.report()['time_spent'];
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(view.report()['time_spent'], first);
      expect(view.report()['is_active'], isFalse);
      expect(first, isA<int>());
      expect(first! as int, greaterThanOrEqualTo(5000000));
    });

    test('custom timings are limited to 50 distinct names', () {
      final ViewScope view = scope();
      for (int index = 0; index < 60; index += 1) {
        view.addTiming('t$index');
      }
      expect(view.customTimings, hasLength(50));
      expect(view.addTiming('t0'), isTrue, reason: 'an existing name updates');
      expect(view.addTiming('t59'), isFalse);
      expect(view.addTiming('   '), isFalse);
    });

    test('timing names keep the characters the contract allows', () {
      expect(timingKey('cart ready!'), 'cart_ready_');
      expect(timingKey('a.b-c_d@e\$f'), 'a.b-c_d@e\$f');
      expect(timingKey('x' * 300), hasLength(128));
    });

    test('memory is reported as average and maximum bytes', () {
      final ViewScope view = scope();
      expect(view.report().containsKey('memory_average'), isFalse);
      view.sampleMemory(100);
      view.sampleMemory(300);
      view.sampleMemory(0);
      final Map<String, Object?> report = view.report();
      expect(report['memory_average'], 200);
      expect(report['memory_max'], 300);
    });
  });
}
