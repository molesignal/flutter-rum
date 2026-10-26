import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';
import 'package:molesignal_flutter/src/configuration.dart';
import 'package:molesignal_flutter/src/session/session_manager.dart';

import 'support/configuration.dart';
import 'support/recording_transport.dart';

NormalizedRumConfiguration _normalized(
  MemoryRumPersistence persistence, {
  double sessionSampleRate = 100,
  double sessionReplaySampleRate = 100,
  Duration sessionInactivityTimeout = const Duration(minutes: 15),
  Duration maxSessionDuration = const Duration(hours: 4),
}) => NormalizedRumConfiguration.from(
  testConfiguration(
    RecordingTransport(validate: false),
    applicationId: 'session-mobile',
    sessionSampleRate: sessionSampleRate,
    sessionReplaySampleRate: sessionReplaySampleRate,
    sessionInactivityTimeout: sessionInactivityTimeout,
    maxSessionDuration: maxSessionDuration,
    persistence: persistence,
  ),
);

const String _storageKey = 'molesignal_rum_session_session-mobile';

/// Rewrites the stored session so it started and was last active in the past.
Future<void> _age(
  MemoryRumPersistence persistence, {
  Duration startedAgo = Duration.zero,
  Duration idleFor = Duration.zero,
}) async {
  final Map<String, dynamic> state =
      jsonDecode(persistence.values[_storageKey]!) as Map<String, dynamic>;
  final Map<String, dynamic> current = state['current'] as Map<String, dynamic>;
  final int now = DateTime.now().microsecondsSinceEpoch;
  current['startedAtMicros'] = now - startedAgo.inMicroseconds;
  current['lastActivityMicros'] = now - idleFor.inMicroseconds;
  await persistence.write(_storageKey, jsonEncode(state));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('session sampling and identity survive restart', () async {
    final MemoryRumPersistence persistence = MemoryRumPersistence();
    final NormalizedRumConfiguration configuration = _normalized(persistence);
    final SessionManager first = await SessionManager.create(
      configuration,
      persistence,
    );
    final RumSession original = first.resolve().session;
    expect(original.id, matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(first.nextReplaySequence(original.id), 1);
    first.markReplayRecorded(original.id);
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
    expect(restored.replayRecorded, isTrue);
  });

  test('a session ends after 15 minutes without activity', () async {
    final MemoryRumPersistence persistence = MemoryRumPersistence();
    final NormalizedRumConfiguration configuration = _normalized(persistence);
    final String firstId = (await SessionManager.create(
      configuration,
      persistence,
    )).resolve().session.id;

    await _age(persistence, idleFor: const Duration(minutes: 14));
    final SessionManager active = await SessionManager.create(
      configuration,
      persistence,
    );
    expect(active.current().id, firstId, reason: 'still within 15 minutes');

    await _age(persistence, idleFor: const Duration(minutes: 16));
    final SessionManager expired = await SessionManager.create(
      configuration,
      persistence,
    );
    expect(expired.current().id, isNot(firstId));
  });

  test('a session ends after four hours however active it is', () async {
    final MemoryRumPersistence persistence = MemoryRumPersistence();
    final NormalizedRumConfiguration configuration = _normalized(persistence);
    final String firstId = (await SessionManager.create(
      configuration,
      persistence,
    )).resolve().session.id;

    await _age(persistence, startedAgo: const Duration(hours: 3, minutes: 59));
    expect(
      (await SessionManager.create(configuration, persistence)).current().id,
      firstId,
    );

    await _age(persistence, startedAgo: const Duration(hours: 4, minutes: 1));
    expect(
      (await SessionManager.create(configuration, persistence)).current().id,
      isNot(firstId),
    );
  });

  test('a running session is renewed on its next use, not before', () async {
    final MemoryRumPersistence persistence = MemoryRumPersistence();
    final SessionManager manager = await SessionManager.create(
      _normalized(persistence),
      persistence,
    );
    final SessionResult first = manager.resolve();
    expect(first.created, isFalse);

    manager.active().lastActivityMicros =
        DateTime.now().microsecondsSinceEpoch -
        const Duration(minutes: 20).inMicroseconds;
    expect(manager.live(), isNull, reason: 'expired sessions are not live');
    expect(
      manager.active().id,
      first.session.id,
      reason: 'passive checks never start a session',
    );

    final SessionResult renewed = manager.resolve();
    expect(renewed.created, isTrue);
    expect(renewed.session.id, isNot(first.session.id));
    expect(manager.live(), same(renewed.session));
  });

  test('the timeouts are configurable', () async {
    final MemoryRumPersistence persistence = MemoryRumPersistence();
    final NormalizedRumConfiguration configuration = _normalized(
      persistence,
      sessionInactivityTimeout: const Duration(minutes: 2),
    );
    expect(configuration.sessionInactivityTimeout, const Duration(minutes: 2));
    expect(configuration.maxSessionDuration, const Duration(hours: 4));
    expect(
      _normalized(MemoryRumPersistence()).sessionInactivityTimeout,
      const Duration(minutes: 15),
    );
  });

  test('sampling decisions are made once per session', () async {
    final MemoryRumPersistence out = MemoryRumPersistence();
    final SessionManager unsampled = await SessionManager.create(
      _normalized(out, sessionSampleRate: 0),
      out,
    );
    expect(unsampled.resolve().session.sampled, isFalse);
    expect(unsampled.resolve().session.replaySampled, isFalse);

    final MemoryRumPersistence replayless = MemoryRumPersistence();
    final RumSession noReplay = (await SessionManager.create(
      _normalized(replayless, sessionReplaySampleRate: 0),
      replayless,
    )).resolve().session;
    expect(noReplay.sampled, isTrue);
    expect(noReplay.replaySampled, isFalse);
  });

  test('an unreadable or foreign stored session is replaced', () async {
    for (final String stored in <String>[
      'not json',
      '{"current":{"id":"has space","startedAtMicros":1,"lastActivityMicros":1,"sampled":true}}',
      '{"current":{"id":"ok","startedAtMicros":"x"}}',
      '[]',
    ]) {
      final MemoryRumPersistence persistence = MemoryRumPersistence(
        <String, String>{_storageKey: stored},
      );
      final SessionManager manager = await SessionManager.create(
        _normalized(persistence),
        persistence,
      );
      expect(manager.current().id, matches(RegExp(r'^[0-9a-f-]{36}$')));
    }
  });
}
