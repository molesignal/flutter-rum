import 'dart:async';
import 'dart:convert';

import '../configuration.dart';
import '../internal/diagnostics.dart';
import '../internal/identifiers.dart';
import '../models.dart';

final class RumSession {
  RumSession({
    required this.id,
    required this.startedAtMicros,
    required this.lastActivityMicros,
    required this.sampled,
    required this.replaySampled,
    required this.reported,
    required this.replaySequence,
    this.eventSequence = 0,
    this.viewCount = 0,
    this.actionCount = 0,
    this.errorCount = 0,
    this.resourceCount = 0,
    this.crashed = false,
    this.pendingClose = false,
    this.finalReported = false,
    this.endedAtMicros,
    this.endReason,
    this.landingPage,
    this.lastPage,
  });

  final String id;
  final int startedAtMicros;
  int lastActivityMicros;
  final bool sampled;
  final bool replaySampled;
  bool reported;
  int replaySequence;
  int eventSequence;
  int viewCount;
  int actionCount;
  int errorCount;
  int resourceCount;
  bool crashed;
  bool pendingClose;
  bool finalReported;
  int? endedAtMicros;
  String? endReason;
  String? landingPage;
  String? lastPage;

  int get durationMicros {
    final int end = endedAtMicros ?? lastActivityMicros;
    final int value = end - startedAtMicros;
    return value < 0 ? 0 : value;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'startedAtMicros': startedAtMicros,
    'lastActivityMicros': lastActivityMicros,
    'sampled': sampled,
    'replaySampled': replaySampled,
    'reported': reported,
    'replaySequence': replaySequence,
    'eventSequence': eventSequence,
    'viewCount': viewCount,
    'actionCount': actionCount,
    'errorCount': errorCount,
    'resourceCount': resourceCount,
    'crashed': crashed,
    'pendingClose': pendingClose,
    'finalReported': finalReported,
    if (endedAtMicros != null) 'endedAtMicros': endedAtMicros,
    if (endReason != null) 'endReason': endReason,
    if (landingPage != null) 'landingPage': landingPage,
    if (lastPage != null) 'lastPage': lastPage,
  };

  static RumSession? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final Object? id = value['id'];
    final Object? startedAtMicros = value['startedAtMicros'];
    final Object? lastActivityMicros = value['lastActivityMicros'];
    final Object? sampled = value['sampled'];
    if (id is! String ||
        id.isEmpty ||
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
      reported: value['reported'] == true,
      replaySequence: _nonNegative(value['replaySequence']),
      eventSequence: _nonNegative(value['eventSequence']),
      viewCount: _nonNegative(value['viewCount']),
      actionCount: _nonNegative(value['actionCount']),
      errorCount: _nonNegative(value['errorCount']),
      resourceCount: _nonNegative(value['resourceCount']),
      crashed: value['crashed'] == true,
      pendingClose: value['pendingClose'] == true,
      finalReported: value['finalReported'] == true,
      endedAtMicros: value['endedAtMicros'] is int
          ? value['endedAtMicros']! as int
          : null,
      endReason: value['endReason'] is String
          ? value['endReason']! as String
          : null,
      landingPage: value['landingPage'] is String
          ? value['landingPage']! as String
          : null,
      lastPage: value['lastPage'] is String
          ? value['lastPage']! as String
          : null,
    );
  }
}

final class SessionResult {
  const SessionResult(
    this.session, {
    required this.created,
    this.closedSessions = const <RumSession>[],
  });

  final RumSession session;
  final bool created;
  final List<RumSession> closedSessions;
}

final class SessionManager {
  SessionManager._(
    this._configuration,
    this._persistence,
    this._storageKey,
    this._session,
    this._pendingFinalizations,
  );

  static Future<SessionManager> create(
    NormalizedRumConfiguration configuration,
    RumPersistence persistence,
  ) async {
    final String storageKey =
        'molesignal_rum_session_${_normalizeStorageKey(configuration.applicationId)}';
    RumSession? stored;
    final List<RumSession> pending = <RumSession>[];
    try {
      final String? raw = await persistence.read(storageKey);
      if (raw != null) {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic> && decoded['current'] != null) {
          stored = RumSession.fromJson(decoded['current']);
          final Object? rawPending = decoded['pending'];
          if (rawPending is List<dynamic>) {
            for (final Object? value in rawPending) {
              final RumSession? session = RumSession.fromJson(value);
              if (session != null && !session.finalReported) {
                pending.add(session);
              }
            }
          }
        } else {
          stored = RumSession.fromJson(decoded);
        }
      }
    } on Object catch (error, stackTrace) {
      reportDiagnostic(
        configuration.onError,
        'RUM session persistence read failed',
        error,
        stackTrace,
      );
    }

    final int now = nowMicros();
    RumSession session = stored ?? _createSession(configuration, now);
    final SessionManager manager = SessionManager._(
      configuration,
      persistence,
      storageKey,
      session,
      pending,
    );
    if (session.pendingClose ||
        manager._expirationReason(session, now) != null) {
      if (!session.finalReported) {
        manager._close(
          session,
          session.endReason ??
              manager._expirationReason(session, now) ??
              'restart',
          now,
        );
        manager._addPending(session);
      }
      session = _createSession(configuration, now);
      manager._session = session;
    }
    await manager.persistNow();
    return manager;
  }

  final NormalizedRumConfiguration _configuration;
  final RumPersistence _persistence;
  final String _storageKey;
  late RumSession _session;
  final List<RumSession> _pendingFinalizations;
  final Map<String, int> _completedReplaySequences = <String, int>{};
  Future<void> _pendingWrite = Future<void>.value();

  SessionResult ensure({bool touch = true}) {
    final int now = nowMicros();
    bool created = false;
    final List<RumSession> closed = <RumSession>[];
    final String? reason = _expirationReason(_session, now);
    if (_session.pendingClose || reason != null) {
      _close(_session, _session.endReason ?? reason ?? 'restart', now);
      _completedReplaySequences[_session.id] = _session.replaySequence;
      if (!_session.finalReported) {
        _addPending(_session);
        closed.add(_session);
      }
      _session = _createSession(_configuration, now);
      created = true;
    }
    if (touch) _session.lastActivityMicros = now;
    if (touch || created) _schedulePersist();
    return SessionResult(
      _session,
      created: created,
      closedSessions: List<RumSession>.unmodifiable(closed),
    );
  }

  RumSession current() => ensure(touch: false).session;

  /// Returns the in-memory session without making replay frames user activity.
  RumSession active() => _session;

  List<RumSession> pendingFinalizations() => List<RumSession>.unmodifiable(
    _pendingFinalizations.where((RumSession session) => !session.finalReported),
  );

  void markReported(String sessionId) {
    if (_session.id != sessionId) return;
    _session.reported = true;
    _schedulePersist();
  }

  void markFinalReported(String sessionId) {
    for (final RumSession session in _pendingFinalizations) {
      if (session.id == sessionId) session.finalReported = true;
    }
    if (_session.id == sessionId) _session.finalReported = true;
    _pendingFinalizations.removeWhere(
      (RumSession session) => session.finalReported,
    );
    _schedulePersist();
  }

  void recordView(RumSession session, String path) {
    if (session.id != _session.id) return;
    session.viewCount += 1;
    if (path.isNotEmpty) {
      session.landingPage ??= path;
      session.lastPage = path;
    }
    _schedulePersist();
  }

  void recordAction(RumSession session) {
    if (session.id != _session.id) return;
    session.actionCount += 1;
    _schedulePersist();
  }

  void recordError(RumSession session, {bool crash = false}) {
    if (session.id != _session.id) return;
    session.errorCount += 1;
    session.crashed = session.crashed || crash;
    _schedulePersist();
  }

  void recordResource(RumSession session) {
    if (session.id != _session.id) return;
    session.resourceCount += 1;
    _schedulePersist();
  }

  Future<RumSession> closeCurrent({
    required String reason,
    bool crashed = false,
  }) async {
    final int now = nowMicros();
    _session.crashed = _session.crashed || crashed;
    _close(_session, reason, now);
    _addPending(_session);
    await persistNow();
    return _session;
  }

  int nextReplaySequence(String sessionId) {
    if (_session.id == sessionId) {
      _session.replaySequence += 1;
      _schedulePersist();
      return _session.replaySequence;
    }
    for (final RumSession session in _pendingFinalizations) {
      if (session.id == sessionId) {
        session.replaySequence += 1;
        _schedulePersist();
        return session.replaySequence;
      }
    }
    final int next = (_completedReplaySequences[sessionId] ?? 0) + 1;
    _completedReplaySequences[sessionId] = next;
    return next;
  }

  int nextEventSequence(String sessionId) {
    if (_session.id == sessionId) {
      _session.eventSequence += 1;
      _schedulePersist();
      return _session.eventSequence;
    }
    for (final RumSession session in _pendingFinalizations) {
      if (session.id == sessionId) {
        session.eventSequence += 1;
        _schedulePersist();
        return session.eventSequence;
      }
    }
    return 1;
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

  void _close(RumSession session, String reason, int now) {
    session.pendingClose = true;
    session.endReason = reason;
    session.endedAtMicros ??= now < session.lastActivityMicros
        ? session.lastActivityMicros
        : now;
  }

  void _addPending(RumSession session) {
    if (_pendingFinalizations.any(
      (RumSession existing) => existing.id == session.id,
    )) {
      return;
    }
    _pendingFinalizations.add(session);
  }

  void _schedulePersist() {
    _pendingWrite = _pendingWrite.then((_) => _writeState());
  }

  Future<void> persistNow() {
    _schedulePersist();
    return _pendingWrite;
  }

  Future<void> _writeState() async {
    final String encoded = jsonEncode(<String, Object?>{
      'version': 2,
      'current': _session.toJson(),
      'pending': _pendingFinalizations
          .where((RumSession session) => !session.finalReported)
          .map((RumSession session) => session.toJson())
          .toList(growable: false),
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
      id: generateId('ses'),
      startedAtMicros: now,
      lastActivityMicros: now,
      sampled: sampled,
      replaySampled: sampled && sample(configuration.sessionReplaySampleRate),
      reported: false,
      replaySequence: 0,
      eventSequence: 0,
    );
  }
}

int _nonNegative(Object? value) => value is int && value >= 0 ? value : 0;

String _normalizeStorageKey(String value) {
  final String sanitized = value.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
  final int end = sanitized.length > 80 ? 80 : sanitized.length;
  return sanitized.substring(0, end);
}
