import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';
import 'package:molesignal_flutter/src/configuration.dart';
import 'package:molesignal_flutter/src/session/session_manager.dart';

const String _clientToken =
    'msrum_aB3kZ1xT9pQrU7nM_dFgHjKl8eRvNcWxYz4tBmEqPaS2vG6Qz';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'session sampling, counters, sequence, and identity survive restart',
    () async {
      final MemoryRumPersistence persistence = MemoryRumPersistence();
      final NormalizedRumConfiguration configuration =
          NormalizedRumConfiguration.from(_configuration(persistence));
      final SessionManager first = await SessionManager.create(
        configuration,
        persistence,
      );
      final RumSession original = first.ensure().session;
      first.recordView(original, '/home');
      first.recordAction(original);
      first.recordError(original, crash: true);
      first.recordResource(original);
      expect(first.nextReplaySequence(original.id), 1);
      expect(first.nextEventSequence(original.id), 1);
      await first.persistNow();

      final SessionManager restarted = await SessionManager.create(
        configuration,
        persistence,
      );
      final RumSession restored = restarted.current();
      expect(restored.id, original.id);
      expect(restored.sampled, original.sampled);
      expect(restored.replaySampled, original.replaySampled);
      expect(restored.startedAtMicros, original.startedAtMicros);
      expect(restored.replaySequence, 1);
      expect(restored.eventSequence, 1);
      expect(restored.viewCount, 1);
      expect(restored.actionCount, 1);
      expect(restored.errorCount, 1);
      expect(restored.resourceCount, 1);
      expect(restored.crashed, isTrue);
      expect(restored.landingPage, '/home');
      expect(restored.lastPage, '/home');

      final RumSession closed = await restarted.closeCurrent(
        reason: 'process_terminated',
      );
      final SessionManager recovered = await SessionManager.create(
        configuration,
        persistence,
      );
      expect(recovered.current().id, isNot(closed.id));
      final RumSession pending = recovered.pendingFinalizations().single;
      expect(pending.id, closed.id);
      expect(pending.pendingClose, isTrue);
      expect(pending.endReason, 'process_terminated');
      expect(pending.durationMicros, greaterThanOrEqualTo(0));
      expect(pending.viewCount, 1);
      expect(pending.crashed, isTrue);
    },
  );
}

RumConfiguration _configuration(MemoryRumPersistence persistence) =>
    RumConfiguration(
      applicationId: 'session-mobile',
      clientToken: _clientToken,
      site: 'https://rum.example.test',
      version: '1.0.0',
      platform: 'ios',
      architecture: 'arm64',
      debugId: 'session-build',
      sessionSampleRate: 100,
      sessionReplaySampleRate: 100,
      trackFlutterErrors: false,
      trackPlatformErrors: false,
      trackAppLifecycle: false,
      trackLongTasks: false,
      trackViewPerformance: false,
      trackAnonymousUser: false,
      persistence: persistence,
    );
