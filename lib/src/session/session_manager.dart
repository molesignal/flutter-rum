import 'dart:async';
import 'dart:convert';

import '../configuration.dart';
import '../internal/diagnostics.dart';
import '../internal/identifiers.dart';
import '../models.dart';

/// Activity is persisted at most this often; restarts lose at most this much.
const int _activityPersistIntervalMicros = 5 * 1000 * 1000;

final RegExp _identifier = RegExp(r'^[A-Za-z0-9._:-]{1,128}$');

/// A user session. The server derives sessions from `view` events, so this is
/// only the identity, the sampling decisions, and the replay bookkeeping.
final class RumSession {
  RumSession({
    required this.id,
    required this.startedAtMicros,
    required this.lastActivityMicros,
    required this.sampled,
    required this.replaySampled,
    this.replaySequence = 0,
    this.replayRecorded = false,
  });

  final String id;
  final int startedAtMicros;
  int lastActivityMicros;
  final bool sampled;
  final bool replaySampled;
  int replaySequence;

  /// A replay event has been queued for this session (`session.has_replay`).
  bool replayRecorded;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'startedAtMicros': startedAtMicros,
    'lastActivityMicros': lastActivityMicros,
    'sampled': sampled,
    'replaySampled': replaySampled,
    'replaySequence': replaySequence,
    'replayRecorded': replayRecorded,
  };

  static RumSession? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final Object? id = value['id'];
    final Object? startedAtMicros = value['startedAtMicros'];
    final Object? lastActivityMicros = value['lastActivityMicros'];
    final Object? sampled = value['sampled'];
    if (id is! String ||
        !_identifier.hasMatch(id) ||
        startedAtMicros is! int ||
        lastActivityMicros is! int ||
        sampled is! bool) {
      return null;
    }
    return RumSession(
      id: id,
      startedAtMicros: startedAtMicros,
      lastActivityMicros: lastActivityMicros,
      sampled: sampled,
      replaySampled: value['replaySampled'] == true,
      replaySequence: _nonNegative(value['replaySequence']),
      replayRecorded: value['replayRecorded'] == true,
    );
  }
}

final class SessionResult {
  const SessionResult(this.session, {required this.created});

  final RumSession session;

  /// The previous session expired (or there was none) and [session] is new.
  final bool created;
}

final class SessionManager {
  SessionManager._(
    this._configuration,
    this._persistence,
    this._storageKey,
    this._session,
  ) : _lastPersistedActivity = _session.lastActivityMicros;

  /// Restores the stored session, or starts one. A session started here
  /// begins at [startedAtMicros] (default: now), so that the application's own
  /// start never precedes the session it belongs to.
  static Future<SessionManager> create(
    NormalizedRumConfiguration configuration,
    RumPersistence persistence, {
    int? startedAtMicros,
  }) async {
    final String storageKey =
        'molesignal_rum_session_${_normalizeStorageKey(configuration.applicationId)}';
    RumSession? stored;
    try {
      final String? raw = await persistence.read(storageKey);
      if (raw != null) {
        final Object? decoded = jsonDecode(raw);
        stored = RumSession.fromJson(
          decoded is Map<String, dynamic> ? decoded['current'] : null,
        );
      }
    } on Object catch (error, stackTrace) {
      reportDiagnostic(
        configuration.onError,
        'RUM session persistence read failed',
        error,
        stackTrace,
      );
    }

    final int now = startedAtMicros ?? nowMicros();
    final SessionManager manager = SessionManager._(
      configuration,
      persistence,
      storageKey,
      stored ?? _createSession(configuration, now),
    );
    if (stored != null && manager._expirationReason(stored, now) != null) {
      manager._session = _createSession(configuration, now);
      manager._lastPersistedActivity = now;
    }
    await manager.persistNow();
    return manager;
  }

  final NormalizedRumConfiguration _configuration;
  final RumPersistence _persistence;
  final String _storageKey;
  RumSession _session;
  int _lastPersistedActivity;
  final Map<String, int> _completedReplaySequences = <String, int>{};
  Future<void> _pendingWrite = Future<void>.value();

  /// The live session, starting a new one when the previous one has expired.
  /// With [touch] the call counts as user activity.
  SessionResult resolve({bool touch = true}) {
    final int now = nowMicros();
    bool created = false;
    if (_expirationReason(_session, now) != null) {
      _completedReplaySequences[_session.id] = _session.replaySequence;
      _session = _createSession(_configuration, now);
      _lastPersistedActivity = now;
      created = true;
    }
    if (touch) _session.lastActivityMicros = now;
    if (created ||
        (touch &&
            now - _lastPersistedActivity >= _activityPersistIntervalMicros)) {
      _lastPersistedActivity = now;
      _schedulePersist();
    }
    return SessionResult(_session, created: created);
  }

  RumSession current() => resolve(touch: false).session;

  /// The session if it has not expired, else `null`. Unlike [resolve] it never
  /// starts a session, so passive measurements such as frame timings cannot
  /// keep or restart one.
  RumSession? live() =>
      _expirationReason(_session, nowMicros()) == null ? _session : null;

  /// Returns the in-memory session without making replay frames user activity.
  RumSession active() => _session;

  void markReplayRecorded(String sessionId) {
    if (_session.id != sessionId || _session.replayRecorded) return;
    _session.replayRecorded = true;
    _schedulePersist();
  }

  int nextReplaySequence(String sessionId) {
    if (_session.id == sessionId) {
      _session.replaySequence += 1;
      _schedulePersist();
      return _session.replaySequence;
    }
    final int next = (_completedReplaySequences[sessionId] ?? 0) + 1;
    _completedReplaySequences[sessionId] = next;
    return next;
  }

  String? _expirationReason(RumSession session, int now) {
    if (now < session.startedAtMicros) return 'clock_reset';
    if (now - session.startedAtMicros >
        _configuration.maxSessionDuration.inMicroseconds) {
      return 'max_duration';
    }
    if (now - session.lastActivityMicros >
        _configuration.sessionInactivityTimeout.inMicroseconds) {
      return 'inactivity';
    }
    return null;
  }

  void _schedulePersist() {
    _pendingWrite = _pendingWrite.then((_) => _writeState());
  }

  Future<void> persistNow() {
    _lastPersistedActivity = _session.lastActivityMicros;
    _schedulePersist();
    return _pendingWrite;
  }

  Future<void> _writeState() async {
    final String encoded = jsonEncode(<String, Object?>{
      'version': 3,
      'current': _session.toJson(),
    });
    try {
      await _persistence.write(_storageKey, encoded);
    } on Object catch (error, stackTrace) {
      reportDiagnostic(
        _configuration.onError,
        'RUM session persistence write failed',
        error,
        stackTrace,
      );
    }
  }

  static RumSession _createSession(
    NormalizedRumConfiguration configuration,
    int now,
  ) {
    final bool sampled = sample(configuration.sessionSampleRate);
    return RumSession(
      id: generateUuid(),
      startedAtMicros: now,
      lastActivityMicros: now,
      sampled: sampled,
      replaySampled: sampled && sample(configuration.sessionReplaySampleRate),
    );
  }
}

int _nonNegative(Object? value) => value is int && value >= 0 ? value : 0;

String _normalizeStorageKey(String value) {
  final String sanitized = value.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
  final int end = sanitized.length > 80 ? 80 : sanitized.length;
  return sanitized.substring(0, end);
}
