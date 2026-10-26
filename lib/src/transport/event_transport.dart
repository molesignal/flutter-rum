import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show compute;

import '../configuration.dart';
import '../internal/diagnostics.dart';
import '../internal/identifiers.dart';
import '../internal/sanitization.dart';
import '../models.dart';
import 'default_transport.dart';
import 'upload_response.dart';

const int _maximumBatchBytes = 48 * 1024;
const int _maximumEventBytes = 1024 * 1024;
const int _targetReplaySegmentBytes = 1024 * 1024;
const int _maximumReplayRequestBytes = 8 * 1024 * 1024;
const int _maximumRejectionDiagnostics = 10;
const int _stateVersion = 2;

/// The contract's event types; anything else in a restored queue is stale.
const Set<String> _eventTypes = <String>{
  'view',
  'action',
  'error',
  'resource',
  'long_task',
  'vital',
};

final class EventTransport {
  EventTransport._(
    this._configuration,
    this._persistence,
    this._nextReplaySequence,
  ) : _transport = _configuration.transport ?? DefaultRumTransport(),
      _endpoints = <RumUploadKind, Uri>{
        for (final RumUploadKind kind in RumUploadKind.values)
          kind: _configuration.endpoint(kind),
      },
      _storageKey =
          'molesignal_rum_queue_${_storageSuffix(_configuration.applicationId)}';

  static Future<EventTransport> create(
    NormalizedRumConfiguration configuration,
    RumPersistence persistence,
    int Function(String sessionId) nextReplaySequence,
  ) async {
    final EventTransport result = EventTransport._(
      configuration,
      persistence,
      nextReplaySequence,
    );
    await result._restore();
    return result;
  }

  final NormalizedRumConfiguration _configuration;
  final RumPersistence _persistence;
  final int Function(String sessionId) _nextReplaySequence;
  final RumTransport _transport;
  final Map<RumUploadKind, Uri> _endpoints;
  final String _storageKey;
  final List<_QueuedEvent> _eventQueue = <_QueuedEvent>[];
  final List<_ReplayEnvelope> _replayQueue = <_ReplayEnvelope>[];
  final List<_ReplaySegment> _replaySegments = <_ReplaySegment>[];
  final Map<String, int> _pendingDropReasons = <String, int>{};
  final Map<RumUploadKind, int> _pausedUntilMicros = <RumUploadKind, int>{};
  final Random _random = Random();

  /// Called before each periodic flush so the client can report the active
  /// view's latest state.
  void Function()? onFlushTick;

  Timer? _eventTimer;
  Timer? _replayTimer;
  Future<RumFlushResult>? _activeFlush;
  Future<void> _pendingWrite = Future<void>.value();
  bool _writeScheduled = false;
  bool _stopped = false;
  bool _closed = false;

  void start() {
    if (_stopped) return;
    _eventTimer ??= Timer.periodic(_configuration.flushInterval, (_) {
      _tick();
      unawaited(_flush(force: false));
    });
    _replayTimer ??= Timer.periodic(_configuration.replayFlushInterval, (_) {
      unawaited(_flush(force: false));
    });
    if (_totalQueued > 0) unawaited(_flush(force: false));
  }

  /// Queues one contract event. A later revision of a view replaces the
  /// revisions of that view that are still waiting: counts are cumulative, so
  /// only the highest revision matters to the receiver.
  bool enqueue(RumContext event) {
    if (_stopped) return false;
    final Object? type = event['type'];
    final int? bytes = _serializedBytes(event, '$type event');
    if (bytes == null) return false;
    if (bytes > _maximumEventBytes || bytes > _configuration.maxQueueBytes) {
      _recordDrop('event_too_large');
      return false;
    }
    final _QueuedEvent queued = _QueuedEvent(
      event: event,
      bytes: bytes,
      createdAtMicros: nowMicros(),
    );
    final String? viewId = queued.viewId;
    if (viewId != null) {
      _eventQueue.removeWhere((_QueuedEvent item) => item.viewId == viewId);
    }
    if (!_makeCapacity(queued.bytes)) return false;
    _eventQueue.add(queued);
    _schedulePersist();
    if (_eventQueue.length >= _configuration.batchSize) {
      unawaited(_flush(force: false));
    }
    return true;
  }

  bool enqueueReplay(String sessionId, RumContext event) {
    if (_stopped) return false;
    final int? bytes = _serializedBytes(event, 'replay event');
    if (bytes == null) return false;
    if (bytes > _maximumReplayRequestBytes ||
        bytes > _configuration.maxQueueBytes) {
      _recordDrop('replay_event_too_large');
      return false;
    }
    final _ReplayEnvelope queued = _ReplayEnvelope(
      sessionId: sessionId,
      event: event,
      bytes: bytes,
      createdAtMicros: nowMicros(),
    );
    if (!_makeCapacity(queued.bytes)) return false;
    _replayQueue.add(queued);
    _schedulePersist();
    if (event['type'] == 2 ||
        _replayQueue.length >= _configuration.replayBatchSize) {
      unawaited(_flush(force: false));
    }
    return true;
  }

  bool isSdkUrl(Uri url) => _endpoints.values.any(
    (Uri endpoint) => url.toString().startsWith(endpoint.toString()),
  );

  Future<RumFlushResult> flush() => _flush(force: true);

  Future<RumFlushResult> stop() async {
    if (_closed) {
      return RumFlushResult(remaining: _totalQueued);
    }
    _stopped = true;
    _eventTimer?.cancel();
    _replayTimer?.cancel();
    _eventTimer = null;
    _replayTimer = null;
    final RumFlushResult result = await _flush(force: true);
    await persistNow();
    try {
      await _transport.close().timeout(_configuration.requestTimeout);
    } on Object catch (error, stackTrace) {
      reportDiagnostic(
        _configuration.onError,
        'RUM transport close failed',
        error,
        stackTrace,
      );
    }
    _closed = true;
    return result;
  }

  void _tick() {
    try {
      onFlushTick?.call();
    } on Object catch (error, stackTrace) {
      reportDiagnostic(
        _configuration.onError,
        'RUM view report failed',
        error,
        stackTrace,
      );
    }
  }

  Future<RumFlushResult> _flush({required bool force}) {
    final Future<RumFlushResult>? active = _activeFlush;
    if (active != null) {
      if (!force) return active;
      return active.then((RumFlushResult first) async {
        if (_totalQueued == 0) return first;
        final RumFlushResult second = await _flush(force: true);
        return _mergeFlushResults(first, second);
      });
    }
    late final Future<RumFlushResult> operation;
    final DateTime deadline = DateTime.now().add(_configuration.flushTimeout);
    operation = _runFlush(force: force, deadline: deadline).whenComplete(() {
      if (identical(_activeFlush, operation)) _activeFlush = null;
    });
    _activeFlush = operation;
    return operation;
  }

  Future<RumFlushResult> _runFlush({
    required bool force,
    required DateTime deadline,
  }) async {
    final _FlushStats stats = _FlushStats(
      initialDropReasons: _pendingDropReasons,
    );
    _pendingDropReasons.clear();
    _dropExpired(stats);
    _createReplaySegments();
    await persistNow();

    while (!_paused(RumUploadKind.events)) {
      if (_deadlineReached(deadline)) {
        stats.timedOut = true;
        break;
      }
      final int now = nowMicros();
      final List<_QueuedEvent> eligible = _eventQueue
          .where((_QueuedEvent item) => force || item.nextAttemptMicros <= now)
          .take(_configuration.batchSize)
          .toList(growable: false);
      if (eligible.isEmpty) break;
      final List<_QueuedEvent> chunk = _fitEventChunk(eligible);
      final _SendOutcome outcome = await _send(
        RumUploadKind.events,
        chunk.map((_QueuedEvent item) => item.event).toList(growable: false),
        deadline,
      );
      if (outcome.result == _SendResult.ok) {
        _eventQueue.removeWhere(chunk.contains);
        final int rejected = _reportRejections(chunk, outcome.answer);
        stats.accepted +=
            outcome.answer.accepted ?? max(0, chunk.length - rejected);
        if (rejected > 0) stats.drop('rejected', rejected);
      } else if (outcome.result == _SendResult.drop) {
        _eventQueue.removeWhere(chunk.contains);
        stats.drop('non_retryable', chunk.length);
      } else {
        _scheduleEventRetry(chunk, outcome.retryAfter);
        stats.retried += chunk.length;
        if (_deadlineReached(deadline)) stats.timedOut = true;
        break;
      }
      await persistNow();
    }

    if (!stats.timedOut) {
      while (_replaySegments.isNotEmpty && !_paused(RumUploadKind.replay)) {
        if (_deadlineReached(deadline)) {
          stats.timedOut = true;
          break;
        }
        final int now = nowMicros();
        final _ReplaySegment? segment = _replaySegments
            .where(
              (_ReplaySegment item) => force || item.nextAttemptMicros <= now,
            )
            .firstOrNull;
        if (segment == null) break;
        final _SendOutcome outcome =
            await _send(RumUploadKind.replay, <String, Object?>{
              'application': _configuration.applicationId,
              'session_id': segment.sessionId,
              'seq': segment.sequence,
              'events': segment.events,
              // A segment has no event to say where its session runs, and what
              // the application keeps of its sessions can depend on it.
              'service': _configuration.service,
              'env': ?_configuration.env,
              'version': _configuration.version,
            }, deadline);
        if (outcome.result == _SendResult.ok) {
          _replaySegments.remove(segment);
          stats.accepted += segment.events.length;
        } else if (outcome.result == _SendResult.drop) {
          _replaySegments.remove(segment);
          stats.drop('non_retryable', segment.events.length);
        } else {
          _scheduleReplayRetry(segment, outcome.retryAfter);
          stats.retried += segment.events.length;
          if (_deadlineReached(deadline)) stats.timedOut = true;
          break;
        }
        await persistNow();
      }
    }

    await persistNow();
    return stats.result(_totalQueued);
  }

  void _createReplaySegments() {
    if (_replayQueue.isEmpty) return;
    final List<_ReplayEnvelope> pending = List<_ReplayEnvelope>.of(
      _replayQueue,
    );
    _replayQueue.clear();
    final Map<String, List<_ReplayEnvelope>> grouped =
        <String, List<_ReplayEnvelope>>{};
    for (final _ReplayEnvelope envelope in pending) {
      grouped
          .putIfAbsent(envelope.sessionId, () => <_ReplayEnvelope>[])
          .add(envelope);
    }
    for (final MapEntry<String, List<_ReplayEnvelope>> entry
        in grouped.entries) {
      final List<List<_ReplayEnvelope>> chunks =
          _chunkBySerializedSize<_ReplayEnvelope>(
            entry.value,
            _configuration.replayBatchSize,
            (List<_ReplayEnvelope> items) => <String, Object?>{
              'application': _configuration.applicationId,
              'session_id': entry.key,
              'seq': 0,
              'events': items
                  .map((_ReplayEnvelope item) => item.event)
                  .toList(growable: false),
            },
            _targetReplaySegmentBytes,
          );
      for (final List<_ReplayEnvelope> chunk in chunks) {
        _replaySegments.add(
          _ReplaySegment(
            sessionId: entry.key,
            sequence: _nextReplaySequence(entry.key),
            events: chunk
                .map((_ReplayEnvelope item) => item.event)
                .toList(growable: false),
            bytes: chunk.fold<int>(
              0,
              (int total, _ReplayEnvelope item) => total + item.bytes,
            ),
            createdAtMicros: chunk.first.createdAtMicros,
          ),
        );
      }
    }
  }

  Future<_SendOutcome> _send(
    RumUploadKind kind,
    Object body,
    DateTime deadline,
  ) async {
    String serialized;
    try {
      serialized = await _encodeJsonAdaptive(body);
    } on Object catch (error, stackTrace) {
      reportDiagnostic(
        _configuration.onError,
        'RUM ${kind.wireName} serialization failed',
        error,
        stackTrace,
      );
      return const _SendOutcome(_SendResult.drop);
    }
    if (kind == RumUploadKind.replay &&
        _jsonSize(body) > _maximumReplayRequestBytes) {
      reportDiagnostic(
        _configuration.onError,
        'RUM replay upload dropped: segment exceeds 8 MiB',
      );
      return const _SendOutcome(_SendResult.drop);
    }
    final Duration remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      return const _SendOutcome(_SendResult.retry);
    }
    final Duration timeout = remaining < _configuration.requestTimeout
        ? remaining
        : _configuration.requestTimeout;
    try {
      final RumTransportResponse response = await _transport
          .send(
            RumTransportRequest(
              url: _endpoints[kind]!,
              body: serialized,
              headers: <String, String>{
                'authorization': 'Bearer ${_configuration.clientToken}',
                'content-type': 'application/json',
              },
              kind: kind,
              compress:
                  kind == RumUploadKind.events &&
                  _configuration.compressRequests,
            ),
          )
          .timeout(timeout);
      if (response.ok) {
        return _SendOutcome(
          _SendResult.ok,
          answer: kind == RumUploadKind.events
              ? parseUploadAnswer(response.body)
              : const UploadAnswer(),
        );
      }
      reportDiagnostic(
        _configuration.onError,
        'RUM ${kind.wireName} upload rejected with HTTP ${response.status}'
        '${_excerpt(response.body)}',
      );
      if (!_retryable(response.status)) {
        return const _SendOutcome(_SendResult.drop);
      }
      final Duration? retryAfter = retryAfterOf(response, DateTime.now());
      if (retryAfter != null) {
        _pausedUntilMicros[kind] = nowMicros() + retryAfter.inMicroseconds;
      }
      return _SendOutcome(_SendResult.retry, retryAfter: retryAfter);
    } on TimeoutException catch (error, stackTrace) {
      reportDiagnostic(
        _configuration.onError,
        'RUM ${kind.wireName} upload timed out',
        error,
        stackTrace,
      );
      return const _SendOutcome(_SendResult.retry);
    } on Object catch (error, stackTrace) {
      reportDiagnostic(
        _configuration.onError,
        'RUM ${kind.wireName} upload failed',
        error,
        stackTrace,
      );
      return const _SendOutcome(_SendResult.retry);
    }
  }

  /// Reports every event the receiver refused. Refused events are never
  /// retried: sending the same bytes again cannot make them valid.
  int _reportRejections(List<_QueuedEvent> chunk, UploadAnswer answer) {
    final Set<int> indexes = <int>{};
    for (final RejectedEvent rejection in answer.rejected) {
      if (rejection.index < 0 || rejection.index >= chunk.length) continue;
      if (!indexes.add(rejection.index)) continue;
      if (indexes.length > _maximumRejectionDiagnostics) continue;
      final Object? type = chunk[rejection.index].event['type'];
      reportDiagnostic(
        _configuration.onError,
        'RUM $type event rejected by the receiver: '
        '${rejection.reason.isEmpty ? 'no reason given' : rejection.reason}',
      );
    }
    if (indexes.length > _maximumRejectionDiagnostics) {
      reportDiagnostic(
        _configuration.onError,
        'RUM ${indexes.length - _maximumRejectionDiagnostics} more events '
        'rejected by the receiver',
      );
    }
    return indexes.length;
  }

  List<_QueuedEvent> _fitEventChunk(List<_QueuedEvent> candidates) {
    final List<_QueuedEvent> result = <_QueuedEvent>[];
    int bytes = 2;
    for (final _QueuedEvent candidate in candidates) {
      final int next = bytes + candidate.bytes + (result.isEmpty ? 0 : 1);
      if (result.isNotEmpty && next > _maximumBatchBytes) break;
      result.add(candidate);
      bytes = next;
    }
    return result;
  }

  bool _paused(RumUploadKind kind) =>
      (_pausedUntilMicros[kind] ?? 0) > nowMicros();

  void _scheduleEventRetry(List<_QueuedEvent> items, Duration? retryAfter) {
    for (final _QueuedEvent item in items) {
      item.attempts += 1;
      item.nextAttemptMicros =
          nowMicros() + _retryDelay(item.attempts, retryAfter);
    }
    _schedulePersist();
  }

  void _scheduleReplayRetry(_ReplaySegment segment, Duration? retryAfter) {
    segment.attempts += 1;
    segment.nextAttemptMicros =
        nowMicros() + _retryDelay(segment.attempts, retryAfter);
    _schedulePersist();
  }

  /// Exponential backoff with jitter, never shorter than the receiver's
  /// `Retry-After`.
  int _retryDelay(int attempts, Duration? retryAfter) {
    final int shift = (attempts - 1).clamp(0, 20);
    final int base = _configuration.retryInitialDelay.inMicroseconds;
    final int cap = _configuration.retryMaxDelay.inMicroseconds;
    final int exponential = min(cap, base * (1 << shift));
    final double jitter = 0.8 + _random.nextDouble() * 0.4;
    final int backoff = max(1, (exponential * jitter).round());
    return max(backoff, retryAfter?.inMicroseconds ?? 0);
  }

  bool _makeCapacity(int incomingBytes) {
    while (_totalQueued >= _configuration.maxQueueSize ||
        _totalBytes + incomingBytes > _configuration.maxQueueBytes) {
      if (!_dropOldest()) {
        _recordDrop('queue_full');
        return false;
      }
      _recordDrop('queue_full');
    }
    return true;
  }

  bool _dropOldest() {
    final List<_QueueHead> heads = <_QueueHead>[
      if (_eventQueue.isNotEmpty)
        _QueueHead(_eventQueue.first.createdAtMicros, () {
          _eventQueue.removeAt(0);
        }),
      if (_replayQueue.isNotEmpty)
        _QueueHead(_replayQueue.first.createdAtMicros, () {
          _replayQueue.removeAt(0);
        }),
      if (_replaySegments.isNotEmpty)
        _QueueHead(_replaySegments.first.createdAtMicros, () {
          _replaySegments.removeAt(0);
        }),
    ];
    if (heads.isEmpty) return false;
    heads.sort(
      (_QueueHead left, _QueueHead right) =>
          left.createdAtMicros.compareTo(right.createdAtMicros),
    );
    heads.first.remove();
    _schedulePersist();
    return true;
  }

  void _dropExpired(_FlushStats stats) {
    final int cutoff = nowMicros() - _configuration.queueItemTtl.inMicroseconds;
    final int before = _totalQueued;
    _eventQueue.removeWhere(
      (_QueuedEvent item) => item.createdAtMicros < cutoff,
    );
    _replayQueue.removeWhere(
      (_ReplayEnvelope item) => item.createdAtMicros < cutoff,
    );
    _replaySegments.removeWhere(
      (_ReplaySegment item) => item.createdAtMicros < cutoff,
    );
    final int removed = before - _totalQueued;
    if (removed > 0) stats.drop('expired', removed);
  }

  int? _serializedBytes(Object value, String label) {
    try {
      return _jsonSize(value);
    } on Object catch (error, stackTrace) {
      _recordDrop('serialization');
      reportDiagnostic(
        _configuration.onError,
        'RUM $label serialization failed',
        error,
        stackTrace,
      );
      return null;
    }
  }

  void _recordDrop(String reason, [int count = 1]) {
    _pendingDropReasons[reason] = (_pendingDropReasons[reason] ?? 0) + count;
    reportDiagnostic(_configuration.onError, 'RUM event dropped: $reason');
  }

  void _schedulePersist() {
    if (_writeScheduled) return;
    _writeScheduled = true;
    _pendingWrite = _pendingWrite.then((_) async {
      _writeScheduled = false;
      await _writeState();
    });
  }

  Future<void> persistNow() {
    _schedulePersist();
    return _pendingWrite;
  }

  Future<void> _writeState() async {
    try {
      if (_totalQueued == 0) {
        await _persistence.remove(_storageKey);
        return;
      }
      final Map<String, Object?> state = <String, Object?>{
        'version': _stateVersion,
        'events': _eventQueue
            .map((_QueuedEvent item) => item.toJson())
            .toList(growable: false),
        'replay_events': _replayQueue
            .map((_ReplayEnvelope item) => item.toJson())
            .toList(growable: false),
        'replay_segments': _replaySegments
            .map((_ReplaySegment item) => item.toJson())
            .toList(growable: false),
      };
      final String encoded = await _encodeJsonAdaptive(state);
      await _persistence.write(_storageKey, encoded);
    } on Object catch (error, stackTrace) {
      reportDiagnostic(
        _configuration.onError,
        'RUM offline queue persistence failed',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _restore() async {
    try {
      final String? raw = await _persistence.read(_storageKey);
      if (raw == null) return;
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final Object? rawEvents = decoded['events'];
      // A queue written by an older SDK holds events for endpoints that no
      // longer exist; they cannot be sent and are discarded.
      if (decoded['version'] == _stateVersion && rawEvents is List<dynamic>) {
        for (final Object? value in rawEvents) {
          final _QueuedEvent? item = _QueuedEvent.fromJson(value);
          if (item != null) _eventQueue.add(item);
        }
      }
      final Object? rawReplay = decoded['replay_events'];
      if (rawReplay is List<dynamic>) {
        for (final Object? value in rawReplay) {
          final _ReplayEnvelope? item = _ReplayEnvelope.fromJson(value);
          if (item != null) _replayQueue.add(item);
        }
      }
      final Object? rawSegments = decoded['replay_segments'];
      if (rawSegments is List<dynamic>) {
        for (final Object? value in rawSegments) {
          final _ReplaySegment? item = _ReplaySegment.fromJson(value);
          if (item != null) _replaySegments.add(item);
        }
      }
      final _FlushStats restored = _FlushStats();
      _dropExpired(restored);
      if (restored.dropped > 0) {
        _pendingDropReasons.addAll(restored.dropReasons);
      }
      while (_totalQueued > _configuration.maxQueueSize ||
          _totalBytes > _configuration.maxQueueBytes) {
        if (!_dropOldest()) break;
        _recordDrop('queue_full_restore');
      }
      await persistNow();
    } on Object catch (error, stackTrace) {
      reportDiagnostic(
        _configuration.onError,
        'RUM offline queue restore failed',
        error,
        stackTrace,
      );
      _eventQueue.clear();
      _replayQueue.clear();
      _replaySegments.clear();
    }
  }

  int get _totalQueued =>
      _eventQueue.length +
      _replayQueue.length +
      _replaySegments.fold<int>(
        0,
        (int total, _ReplaySegment item) => total + item.events.length,
      );

  int get _totalBytes =>
      _eventQueue.fold<int>(
        0,
        (int total, _QueuedEvent item) => total + item.bytes,
      ) +
      _replayQueue.fold<int>(
        0,
        (int total, _ReplayEnvelope item) => total + item.bytes,
      ) +
      _replaySegments.fold<int>(
        0,
        (int total, _ReplaySegment item) => total + item.bytes,
      );
}

RumFlushResult _mergeFlushResults(RumFlushResult first, RumFlushResult second) {
  final Map<String, int> reasons = <String, int>{...first.dropReasons};
  for (final MapEntry<String, int> entry in second.dropReasons.entries) {
    reasons[entry.key] = (reasons[entry.key] ?? 0) + entry.value;
  }
  return RumFlushResult(
    accepted: first.accepted + second.accepted,
    retried: first.retried + second.retried,
    dropped: first.dropped + second.dropped,
    remaining: second.remaining,
    timedOut: first.timedOut || second.timedOut,
    dropReasons: Map<String, int>.unmodifiable(reasons),
  );
}

final class _QueuedEvent {
  _QueuedEvent({
    required this.event,
    required this.bytes,
    required this.createdAtMicros,
    this.attempts = 0,
    this.nextAttemptMicros = 0,
  }) : viewId = _viewIdOf(event);

  final RumContext event;
  final int bytes;
  final int createdAtMicros;

  /// `view.id` of a `view` event, which later revisions replace.
  final String? viewId;
  int attempts;
  int nextAttemptMicros;

  Map<String, Object?> toJson() => <String, Object?>{
    'event': event,
    'bytes': bytes,
    'created_at_micros': createdAtMicros,
    'attempts': attempts,
    'next_attempt_micros': nextAttemptMicros,
  };

  static _QueuedEvent? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final RumContext? event = _context(value['event']);
    final int? bytes = _positiveInt(value['bytes']);
    final int? created = _positiveInt(value['created_at_micros']);
    if (event == null ||
        !_eventTypes.contains(event['type']) ||
        bytes == null ||
        created == null) {
      return null;
    }
    return _QueuedEvent(
      event: event,
      bytes: bytes,
      createdAtMicros: created,
      attempts: _nonNegativeInt(value['attempts']),
      nextAttemptMicros: _nonNegativeInt(value['next_attempt_micros']),
    );
  }

  static String? _viewIdOf(RumContext event) {
    if (event['type'] != 'view') return null;
    final Object? view = event['view'];
    final Object? id = view is Map<dynamic, dynamic> ? view['id'] : null;
    return id is String ? id : null;
  }
}

final class _ReplayEnvelope {
  const _ReplayEnvelope({
    required this.sessionId,
    required this.event,
    required this.bytes,
    required this.createdAtMicros,
  });

  final String sessionId;
  final RumContext event;
  final int bytes;
  final int createdAtMicros;

  Map<String, Object?> toJson() => <String, Object?>{
    'session_id': sessionId,
    'event': event,
    'bytes': bytes,
    'created_at_micros': createdAtMicros,
  };

  static _ReplayEnvelope? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final Object? sessionId = value['session_id'];
    final RumContext? event = _context(value['event']);
    final int? bytes = _positiveInt(value['bytes']);
    final int? created = _positiveInt(value['created_at_micros']);
    if (sessionId is! String ||
        sessionId.isEmpty ||
        event == null ||
        bytes == null ||
        created == null) {
      return null;
    }
    return _ReplayEnvelope(
      sessionId: sessionId,
      event: event,
      bytes: bytes,
      createdAtMicros: created,
    );
  }
}

final class _ReplaySegment {
  _ReplaySegment({
    required this.sessionId,
    required this.sequence,
    required List<RumContext> events,
    required this.bytes,
    required this.createdAtMicros,
    this.attempts = 0,
    this.nextAttemptMicros = 0,
  }) : events = List<RumContext>.unmodifiable(events);

  final String sessionId;
  final int sequence;
  final List<RumContext> events;
  final int bytes;
  final int createdAtMicros;
  int attempts;
  int nextAttemptMicros;

  Map<String, Object?> toJson() => <String, Object?>{
    'session_id': sessionId,
    'sequence': sequence,
    'events': events,
    'bytes': bytes,
    'created_at_micros': createdAtMicros,
    'attempts': attempts,
    'next_attempt_micros': nextAttemptMicros,
  };

  static _ReplaySegment? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final Object? sessionId = value['session_id'];
    final int? sequence = _positiveInt(value['sequence']);
    final int? bytes = _positiveInt(value['bytes']);
    final int? created = _positiveInt(value['created_at_micros']);
    final Object? rawEvents = value['events'];
    if (sessionId is! String ||
        sessionId.isEmpty ||
        sequence == null ||
        bytes == null ||
        created == null ||
        rawEvents is! List<dynamic>) {
      return null;
    }
    final List<RumContext> events = rawEvents
        .map(_context)
        .whereType<RumContext>()
        .toList(growable: false);
    if (events.length != rawEvents.length || events.isEmpty) return null;
    return _ReplaySegment(
      sessionId: sessionId,
      sequence: sequence,
      events: events,
      bytes: bytes,
      createdAtMicros: created,
      attempts: _nonNegativeInt(value['attempts']),
      nextAttemptMicros: _nonNegativeInt(value['next_attempt_micros']),
    );
  }
}

final class _FlushStats {
  _FlushStats({Map<String, int>? initialDropReasons})
    : dropReasons = <String, int>{...?initialDropReasons},
      dropped = initialDropReasons?.values.fold<int>(0, (a, b) => a + b) ?? 0;

  int accepted = 0;
  int retried = 0;
  int dropped;
  bool timedOut = false;
  final Map<String, int> dropReasons;

  void drop(String reason, [int count = 1]) {
    dropped += count;
    dropReasons[reason] = (dropReasons[reason] ?? 0) + count;
  }

  RumFlushResult result(int remaining) => RumFlushResult(
    accepted: accepted,
    retried: retried,
    dropped: dropped,
    remaining: remaining,
    timedOut: timedOut,
    dropReasons: Map<String, int>.unmodifiable(dropReasons),
  );
}

final class _QueueHead {
  const _QueueHead(this.createdAtMicros, this.remove);

  final int createdAtMicros;
  final void Function() remove;
}

enum _SendResult { ok, drop, retry }

final class _SendOutcome {
  const _SendOutcome(
    this.result, {
    this.answer = const UploadAnswer(),
    this.retryAfter,
  });

  final _SendResult result;
  final UploadAnswer answer;
  final Duration? retryAfter;
}

List<List<T>> _chunkBySerializedSize<T>(
  List<T> items,
  int maximumItems,
  Object Function(List<T> items) wrap,
  int maximumBytes,
) {
  final List<List<T>> chunks = <List<T>>[];
  List<T> current = <T>[];
  for (final T item in items) {
    final List<T> candidate = <T>[...current, item];
    final int bytes = _jsonSize(wrap(candidate));
    if (current.isNotEmpty &&
        (candidate.length > maximumItems || bytes > maximumBytes)) {
      chunks.add(current);
      current = <T>[item];
    } else {
      current = candidate;
    }
  }
  if (current.isNotEmpty) chunks.add(current);
  return chunks;
}

/// Network failures, request timeouts, rate limiting, and server errors are
/// worth another attempt; any other refusal will not change.
bool _retryable(int status) =>
    status == 0 || status == 408 || status == 429 || status >= 500;

bool _deadlineReached(DateTime deadline) => !DateTime.now().isBefore(deadline);

/// A short, sanitized quote of an error body for diagnostics.
String _excerpt(String? body) {
  final String text = (body ?? '').trim();
  if (text.isEmpty) return '';
  return ': ${sanitizeText(text.length > 200 ? text.substring(0, 200) : text)}';
}

RumContext? _context(Object? value) => value is Map<dynamic, dynamic>
    ? value.map<String, Object?>(
        (dynamic key, dynamic item) =>
            MapEntry<String, Object?>(key.toString(), item),
      )
    : null;

int? _positiveInt(Object? value) => value is int && value > 0 ? value : null;

int _nonNegativeInt(Object? value) => value is int && value >= 0 ? value : 0;

String _storageSuffix(String value) {
  final String sanitized = value.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
  return sanitized.length <= 80 ? sanitized : sanitized.substring(0, 80);
}

String _encodeJson(Object? value) => jsonEncode(value);

Future<String> _encodeJsonAdaptive(Object? value) {
  if (_jsonSize(value) < 64 * 1024) {
    return Future<String>.value(jsonEncode(value));
  }
  return compute(_encodeJson, value);
}

int _jsonSize(Object? value) {
  if (value == null) return 4;
  if (value is bool) return value ? 4 : 5;
  if (value is num) return value.toString().length;
  if (value is String) return _jsonStringSize(value);
  if (value is List<dynamic>) {
    int size = 2;
    for (int index = 0; index < value.length; index += 1) {
      if (index > 0) size += 1;
      size += _jsonSize(value[index]);
    }
    return size;
  }
  if (value is Map<dynamic, dynamic>) {
    int size = 2;
    int index = 0;
    for (final MapEntry<dynamic, dynamic> entry in value.entries) {
      if (index > 0) size += 1;
      size += _jsonStringSize(entry.key.toString()) + 1;
      size += _jsonSize(entry.value);
      index += 1;
    }
    return size;
  }
  return _jsonStringSize(value.toString());
}

int _jsonStringSize(String value) {
  if (value.startsWith('data:image/png;base64,')) return value.length + 2;
  int escapes = 0;
  for (final int codeUnit in value.codeUnits) {
    if (codeUnit == 0x22 || codeUnit == 0x5c) {
      escapes += 1;
    } else if (codeUnit < 0x20) {
      escapes += 5;
    }
  }
  return utf8.encode(value).length + escapes + 2;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final Iterator<T> iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
