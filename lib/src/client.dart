import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'configuration.dart';
import 'instrumentation/flutter_instrumentation.dart';
import 'instrumentation/sink.dart';
import 'internal/diagnostics.dart';
import 'internal/environment.dart';
import 'internal/error_description.dart' as error_description;
import 'internal/identifiers.dart';
import 'internal/sanitization.dart';
import 'internal/urls.dart';
import 'models.dart';
import 'persistence.dart';
import 'replay/capture.dart';
import 'session/identity.dart';
import 'session/session_manager.dart';
import 'transport/event_transport.dart';

/// Public operations supported by a MoleSignal RUM client.
abstract interface class RumClient {
  void setUser(RumUser user);
  void clearUser();
  RumUser? getUser();

  void setGlobalContext(RumContext context);
  void setGlobalContextProperty(String key, Object? value);
  void removeGlobalContextProperty(String key);
  RumContext getGlobalContext();

  void addAction(String name, {RumContext context});
  void addInteraction(String name, {RumContext context});
  void addError(
    Object error, {
    StackTrace? stackTrace,
    List<RumStackFrame> frames,
    RumContext context,
  });
  void addResource(RumResource resource);
  void addPerformanceMetric(RumPerformanceMetric metric);
  void startView(String name, {String? path, RumContext context});

  void startSessionReplayRecording();
  void stopSessionReplayRecording();

  RumInternalContext getInternalContext();
  Future<RumFlushResult> flush();
  Future<RumFlushResult> stop();
}

/// Flutter implementation of the MoleSignal RUM client.
final class MoleSignalRumClient implements RumClient, RumInstrumentationSink {
  MoleSignalRumClient._({
    required NormalizedRumConfiguration configuration,
    required SessionManager sessionManager,
    required EventTransport eventTransport,
    required RumContext environment,
    required String? anonymousUserId,
    required Stopwatch startupStopwatch,
  }) : _configuration = configuration,
       _sessionManager = sessionManager,
       _eventTransport = eventTransport,
       _environment = environment,
       _anonymousUserId = anonymousUserId,
       _startupStopwatch = startupStopwatch,
       _user = configuration.user,
       _globalContext = Map<String, Object?>.from(configuration.globalContext);

  static Future<MoleSignalRumClient> create(
    RumConfiguration configuration,
  ) async {
    final Stopwatch startupStopwatch = Stopwatch()..start();
    WidgetsFlutterBinding.ensureInitialized();
    final NormalizedRumConfiguration normalized =
        NormalizedRumConfiguration.from(configuration);
    final RumPersistence persistence =
        normalized.persistence ?? SharedPreferencesRumPersistence();
    await validateCredentialApplicationBinding(normalized, persistence);
    final SessionManager sessionManager = await SessionManager.create(
      normalized,
      persistence,
    );
    final String? anonymousUserId = await getAnonymousUserId(
      normalized,
      persistence,
    );
    final EventTransport eventTransport = await EventTransport.create(
      normalized,
      persistence,
      sessionManager.nextReplaySequence,
    );
    final MoleSignalRumClient client = MoleSignalRumClient._(
      configuration: normalized,
      sessionManager: sessionManager,
      eventTransport: eventTransport,
      environment: readFlutterEnvironment(),
      anonymousUserId: anonymousUserId,
      startupStopwatch: startupStopwatch,
    );
    client._start();
    client._reportRecoveredSessions();
    return client;
  }

  final NormalizedRumConfiguration _configuration;
  final SessionManager _sessionManager;
  final EventTransport _eventTransport;
  final RumContext _environment;
  final String? _anonymousUserId;
  final Stopwatch _startupStopwatch;

  late final FlutterRumInstrumentation _instrumentation;
  RumUser? _user;
  RumContext _globalContext;
  String _currentViewPath = '';
  String? _lastViewKey;
  int _lastViewAtMicros = 0;
  _InteractionSample? _lastExplicitInteraction;
  final Map<String, int> _recentErrors = <String, int>{};
  RumReplayCapture? _replayCapture;
  bool? _replayOverride;
  int _visualChangeId = 0;
  Stopwatch? _pendingViewRender;
  String? _pendingViewName;
  bool _stopped = false;
  bool _stopCompleted = false;
  Future<RumFlushResult>? _stopFuture;
  bool _startupRecorded = false;

  bool get resourceTrackingEnabled =>
      !_stopped && _configuration.trackResources;

  bool get userInteractionTrackingEnabled =>
      !_stopped && _configuration.trackUserInteractions;

  bool get frustrationTrackingEnabled =>
      !_stopped && _configuration.trackFrustrations;

  int get visualChangeId => _visualChangeId;

  RumPrivacyLevel get privacyLevel => _configuration.defaultPrivacyLevel;

  RumSessionReplayConfiguration get replayConfiguration =>
      _configuration.sessionReplay;

  RumDiagnosticHandler? get diagnosticHandler => _configuration.onError;

  String get replayPage {
    final String path = _currentViewPath.isEmpty ? '/' : _currentViewPath;
    return 'molesignal://flutter$path';
  }

  void _start() {
    _eventTransport.start();
    _instrumentation = FlutterRumInstrumentation(_configuration, this)..start();
  }

  @override
  void setUser(RumUser user) {
    final String id = user.id.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(user.id, 'user.id', 'must be non-empty');
    }
    _user = RumUser(
      id: id,
      name: user.name,
      email: user.email,
      attributes: sanitizeContext(user.attributes),
    );
  }

  @override
  void clearUser() {
    _user = null;
  }

  @override
  RumUser? getUser() {
    final RumUser? user = _user;
    if (user == null) return null;
    return RumUser(
      id: user.id,
      name: user.name,
      email: user.email,
      attributes: Map<String, Object?>.from(user.attributes),
    );
  }

  @override
  void setGlobalContext(RumContext context) {
    _globalContext = sanitizeContext(context);
  }

  @override
  void setGlobalContextProperty(String key, Object? value) {
    final String normalized = key.trim();
    if (normalized.isNotEmpty) _globalContext[normalized] = value;
  }

  @override
  void removeGlobalContextProperty(String key) {
    _globalContext.remove(key);
  }

  @override
  RumContext getGlobalContext() => sanitizeContext(_globalContext);

  @override
  void addAction(
    String name, {
    RumContext context = const <String, Object?>{},
  }) {
    final String normalized = name.trim();
    if (normalized.isEmpty || _stopped) return;
    _recordAction(
      _ActionInput(type: 'custom', name: normalized, context: context),
    );
  }

  @override
  void addInteraction(
    String name, {
    RumContext context = const <String, Object?>{},
  }) {
    final String normalized = name.trim();
    if (normalized.isEmpty || _stopped) return;
    _lastExplicitInteraction = _InteractionSample.fromContext(
      nowMicros(),
      context,
    );
    _recordAction(
      _ActionInput(type: 'tap', name: normalized, context: context),
    );
  }

  void recordAutomaticInteraction(
    String name, {
    required Offset position,
    RumContext context = const <String, Object?>{},
  }) {
    if (!userInteractionTrackingEnabled) return;
    final int timestamp = nowMicros();
    final _InteractionSample? explicit = _lastExplicitInteraction;
    if (explicit != null &&
        timestamp - explicit.timestampMicros <=
            _configuration.actionDeduplicationWindow.inMicroseconds &&
        explicit.isNear(position)) {
      return;
    }
    _recordAction(
      _ActionInput(
        type: 'tap',
        name: name,
        timestampMicros: timestamp,
        context: <String, Object?>{
          ...context,
          'x': position.dx.round(),
          'y': position.dy.round(),
          'selector': 'flutter:interactive',
        },
      ),
    );
  }

  void recordFrustration(
    String type,
    String name, {
    RumContext context = const <String, Object?>{},
  }) {
    if (!frustrationTrackingEnabled || _stopped) return;
    _recordAction(_ActionInput(type: type, name: name, context: context));
  }

  @override
  void startView(
    String name, {
    String? path,
    RumContext context = const <String, Object?>{},
  }) {
    final String logicalName = name.trim();
    if (logicalName.isEmpty || _stopped) return;
    final String candidatePath = path?.trim().isNotEmpty == true
        ? path!.trim()
        : logicalName;
    final String url = sanitizeUrl(
      candidatePath,
      _configuration.trackUrlQueryString,
    );
    final String nextPath = pagePath(url);
    final int timestamp = nowMicros();
    final String viewKey = '$logicalName|$nextPath';
    if (_lastViewKey == viewKey &&
        timestamp - _lastViewAtMicros <=
            _configuration.actionDeduplicationWindow.inMicroseconds) {
      return;
    }
    _lastViewKey = viewKey;
    _lastViewAtMicros = timestamp;
    _currentViewPath = nextPath;
    _visualChangeId += 1;
    if (_configuration.trackViewPerformance) {
      _pendingViewName = logicalName;
      _pendingViewRender = Stopwatch()..start();
    }
    _recordAction(
      _ActionInput(
        type: 'view',
        name: 'View $logicalName',
        url: url,
        timestampMicros: timestamp,
        context: <String, Object?>{
          ...context,
          'path': _currentViewPath,
          'view_name': logicalName,
        },
      ),
    );
  }

  @override
  void addResource(RumResource resource) {
    if (!resourceTrackingEnabled ||
        isSdkUrl(resource.url) ||
        !shouldTrackUrl(resource.url)) {
      return;
    }
    if (resource.duration.isNegative ||
        !_validMetricValue(resource.duration.inMicroseconds) ||
        (resource.requestSize != null && resource.requestSize! < 0) ||
        (resource.responseSize != null && resource.responseSize! < 0)) {
      reportDiagnostic(
        _configuration.onError,
        'RUM resource dropped: invalid duration or size',
      );
      return;
    }
    _visualChangeId += 1;
    final String method = resource.method.trim().toUpperCase();
    final String url = sanitizeUrl(
      resource.url.toString(),
      _configuration.trackUrlQueryString,
    );
    _recordAction(
      _ActionInput(
        type: 'resource',
        name: '$method ${resource.url.path.isEmpty ? '/' : resource.url.path}',
        url: url,
        durationMs: resource.duration.inMicroseconds / 1000,
        durationUs: resource.duration.inMicroseconds,
        status: resource.status,
        traceContext: resource.traceContext,
        context: <String, Object?>{
          ...resource.context,
          'method': method,
          'initiator': resource.initiator,
          'metric': RumPerformanceMetricKind.network.wireName,
          'metric_value': resource.duration.inMicroseconds,
          'metric_unit': RumMetricUnit.microsecond.wireName,
          'clock': RumMetricClock.monotonic.wireName,
          if (resource.requestSize != null)
            'request_size': resource.requestSize,
          if (resource.responseSize != null)
            'response_size': resource.responseSize,
          if (resource.errorType != null) 'error_type': resource.errorType,
          if (resource.errorCode != null) 'error_code': resource.errorCode,
          if (resource.errorMessage != null)
            'error_message': sanitizeText(resource.errorMessage!),
        },
      ),
    );
  }

  @override
  void addError(
    Object error, {
    StackTrace? stackTrace,
    List<RumStackFrame> frames = const <RumStackFrame>[],
    RumContext context = const <String, Object?>{},
  }) {
    _recordError(
      error,
      stackTrace: stackTrace,
      frames: frames,
      context: context,
      source: 'manual',
    );
  }

  @override
  void addPerformanceMetric(RumPerformanceMetric metric) {
    if (_stopped) return;
    final double numericValue = metric.value.toDouble();
    final int timestamp = metric.timestampMicros ?? nowMicros();
    if (!_validMetricValue(numericValue) ||
        numericValue < 0 ||
        !_validEpochMicros(timestamp)) {
      throw ArgumentError(
        'RUM performance values must be finite, non-negative, and use a valid epoch-microsecond timestamp',
      );
    }
    _recordAction(
      _ActionInput(
        type: 'performance',
        name: metric.kind.wireName,
        timestampMicros: timestamp,
        durationUs: metric.unit == RumMetricUnit.microsecond
            ? numericValue.round()
            : null,
        durationMs: metric.unit == RumMetricUnit.microsecond
            ? numericValue / 1000
            : null,
        context: <String, Object?>{
          ...metric.context,
          'metric': metric.kind.wireName,
          'metric_value': metric.value,
          'metric_unit': metric.unit.wireName,
          'clock': metric.clock.wireName,
        },
      ),
    );
  }

  @override
  void recordCapturedError(
    Object error, {
    StackTrace? stackTrace,
    RumContext context = const <String, Object?>{},
    required String source,
  }) {
    _recordError(
      error,
      stackTrace: stackTrace,
      frames: const <RumStackFrame>[],
      context: context,
      source: source,
    );
  }

  @override
  void recordFrameTiming(FrameTiming timing) {
    if (_stopped) return;
    if (!_startupRecorded) {
      _startupRecorded = true;
      _startupStopwatch.stop();
      final int startupMicros = _startupStopwatch.elapsedMicroseconds;
      if (_validMetricValue(startupMicros)) {
        addPerformanceMetric(
          RumPerformanceMetric(
            kind: RumPerformanceMetricKind.coldStart,
            value: startupMicros,
            unit: RumMetricUnit.microsecond,
            context: const <String, Object?>{
              'source': 'sdk_init_to_first_frame',
            },
          ),
        );
      }
    }
    final Stopwatch? render = _pendingViewRender;
    if (render != null && _configuration.trackViewPerformance) {
      render.stop();
      _pendingViewRender = null;
      final String viewName = _pendingViewName ?? _currentViewPath;
      _pendingViewName = null;
      _recordAction(
        _ActionInput(
          type: 'view_performance',
          name: 'Render $viewName',
          durationMs: render.elapsedMicroseconds / 1000,
          durationUs: render.elapsedMicroseconds,
          context: <String, Object?>{
            'metric': RumPerformanceMetricKind.viewLoad.wireName,
            'metric_value': render.elapsedMicroseconds,
            'metric_unit': RumMetricUnit.microsecond.wireName,
            'clock': RumMetricClock.monotonic.wireName,
            'build_duration_ms': timing.buildDuration.inMicroseconds / 1000,
            'build_duration_us': timing.buildDuration.inMicroseconds,
            'raster_duration_ms': timing.rasterDuration.inMicroseconds / 1000,
            'raster_duration_us': timing.rasterDuration.inMicroseconds,
            'vsync_overhead_ms': timing.vsyncOverhead.inMicroseconds / 1000,
            'vsync_overhead_us': timing.vsyncOverhead.inMicroseconds,
          },
        ),
      );
    }
    if (_configuration.trackLongFrames &&
        timing.totalSpan >= _configuration.longFrameThreshold) {
      final bool frozen =
          timing.totalSpan >= _configuration.frozenFrameThreshold;
      final RumPerformanceMetricKind metric = frozen
          ? RumPerformanceMetricKind.frozenFrame
          : RumPerformanceMetricKind.slowFrame;
      _recordAction(
        _ActionInput(
          type: frozen ? 'frozen_frame' : 'long_task',
          name: frozen ? 'Frozen Flutter frame' : 'Slow Flutter frame',
          durationMs: timing.totalSpan.inMicroseconds / 1000,
          durationUs: timing.totalSpan.inMicroseconds,
          context: <String, Object?>{
            'metric': metric.wireName,
            'metric_value': timing.totalSpan.inMicroseconds,
            'metric_unit': RumMetricUnit.microsecond.wireName,
            'clock': RumMetricClock.monotonic.wireName,
            'jank': timing.totalSpan >= const Duration(microseconds: 33334),
            'build_duration_ms': timing.buildDuration.inMicroseconds / 1000,
            'build_duration_us': timing.buildDuration.inMicroseconds,
            'raster_duration_ms': timing.rasterDuration.inMicroseconds / 1000,
            'raster_duration_us': timing.rasterDuration.inMicroseconds,
            'vsync_overhead_ms': timing.vsyncOverhead.inMicroseconds / 1000,
            'vsync_overhead_us': timing.vsyncOverhead.inMicroseconds,
          },
        ),
      );
    }
  }

  @override
  void handleLifecycleState(AppLifecycleState state) {
    if (_stopped) return;
    if (state == AppLifecycleState.resumed) {
      _recordAction(const _ActionInput(type: 'lifecycle', name: 'App resumed'));
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _recordAction(
        _ActionInput(
          type: 'lifecycle',
          name: 'App ${state.name}',
          context: <String, Object?>{'state': state.name},
        ),
      );
      if (state == AppLifecycleState.detached) {
        unawaited(_closeForLifecycle());
      } else {
        unawaited(flush());
      }
    }
  }

  bool isSdkUrl(Uri url) => _eventTransport.isSdkUrl(url);

  bool shouldTrackUrl(Uri url) =>
      !matchesUrl(url.toString(), _configuration.excludedUrls);

  bool shouldReadTrace(Uri url) =>
      _configuration.allowedTracingUrls.isEmpty ||
      matchesUrl(url.toString(), _configuration.allowedTracingUrls);

  @override
  RumInternalContext getInternalContext() {
    final RumSession session = _sessionManager.current();
    return RumInternalContext(
      applicationId: _configuration.applicationId,
      sessionId: session.sampled ? session.id : null,
      userId: _currentUserId,
      service: _configuration.service,
      environment: _configuration.env,
      version: _configuration.version,
      platform: _configuration.platform,
      architecture: _configuration.architecture,
      debugId: _configuration.debugId,
    );
  }

  @override
  void startSessionReplayRecording() {
    if (_stopped) return;
    _replayOverride = true;
    _prepareSession();
  }

  @override
  void stopSessionReplayRecording() {
    _replayOverride = false;
    _replayCapture?.stop();
  }

  void attachReplayCapture(RumReplayCapture capture) {
    if (_stopped || identical(_replayCapture, capture)) return;
    _replayCapture?.stop();
    _replayCapture = capture;
    _prepareSession();
  }

  void detachReplayCapture(RumReplayCapture capture) {
    if (!identical(_replayCapture, capture)) return;
    capture.stop();
    _replayCapture = null;
  }

  @override
  Future<RumFlushResult> flush() async {
    await _sessionManager.persistNow();
    return _eventTransport.flush();
  }

  @override
  Future<RumFlushResult> stop() {
    if (_stopCompleted) {
      return Future<RumFlushResult>.value(const RumFlushResult());
    }
    final Future<RumFlushResult>? active = _stopFuture;
    if (active != null) return active;
    final Future<RumFlushResult> operation = _stop();
    _stopFuture = operation;
    return operation;
  }

  Future<RumFlushResult> _stop() async {
    try {
      if (_stopped) return const RumFlushResult();
      final RumSession session = await _sessionManager.closeCurrent(
        reason: 'stopped',
      );
      _reportFinalSession(session);
      await _sessionManager.persistNow();
      _stopped = true;
      _replayCapture?.stop();
      _instrumentation.stop();
      return await _eventTransport.stop();
    } finally {
      _stopCompleted = true;
    }
  }

  Future<void> _closeForLifecycle() async {
    final RumSession session = await _sessionManager.closeCurrent(
      reason: 'detached',
    );
    _reportFinalSession(session);
    await flush();
  }

  void _recordAction(_ActionInput input) {
    if (_stopped) return;
    try {
      final RumSession? session = _prepareSession();
      if (session == null || !session.sampled) return;
      final int timestamp = input.timestampMicros ?? nowMicros();
      if (!_validEpochMicros(timestamp) ||
          (input.durationUs != null && !_validMetricValue(input.durationUs!))) {
        reportDiagnostic(
          _configuration.onError,
          'RUM action dropped: invalid timestamp or duration',
        );
        return;
      }
      switch (input.type) {
        case 'view':
          _sessionManager.recordView(session, _currentViewPath);
          break;
        case 'resource':
          _sessionManager.recordResource(session);
          break;
        case 'error' ||
            'view_performance' ||
            'performance' ||
            'long_task' ||
            'frozen_frame':
          break;
        default:
          _sessionManager.recordAction(session);
      }
      final RumContext payload = _compact(<String, Object?>{
        ...sanitizeContext(_globalContext),
        ...sanitizeContext(input.context),
        if (_currentViewPath.isNotEmpty) 'path': _currentViewPath,
        'application': _configuration.applicationId,
        'environment': _configuration.env,
        'version': _configuration.version,
        'platform': _configuration.platform,
        'architecture': _configuration.architecture,
        'debug_id': _configuration.debugId,
        'browser': _environment['browser'],
        'os': _environment['os'],
        'device': _environment['device'],
        if (_user != null) 'user': sanitizeContext(_user!.toJson()),
      });
      final RumContext event = _compact(<String, Object?>{
        ..._commonFields(timestamp, session),
        'timestamp': timestamp,
        'session_id': session.id,
        'ts_micros': timestamp,
        'type': input.type,
        'name': input.name,
        if (_currentViewPath.isNotEmpty) 'page': _currentViewPath,
        'url': input.url,
        'duration_ms': input.durationMs,
        'duration_us': input.durationUs,
        'status': input.status,
        'trace_id': input.traceContext?.traceId,
        'parent_span_id': input.traceContext?.parentSpanId,
        'service': _configuration.service,
        'payload': payload,
      });
      _enqueue(RumEventKind.action, event);
      if (_isReplayEnabled(session)) {
        _recordReplay(
          session,
          _compact(<String, Object?>{
            'type': input.type,
            'ts': timestamp ~/ 1000,
            if (_currentViewPath.isNotEmpty) 'href': replayPage,
            'url': input.url,
            'name': input.name,
            'selector': input.context['selector'],
            'duration_ms': input.durationMs,
            'duration_us': input.durationUs,
            'status': input.status,
            'payload': sanitizeContext(input.context),
          }),
        );
        final Object? x = input.context['x'];
        final Object? y = input.context['y'];
        if (x is num && y is num) {
          _replayCapture?.recordPointer(
            Offset(x.toDouble(), y.toDouble()),
            timestampMilliseconds: timestamp ~/ 1000,
          );
        }
        if (_configuration.sessionReplay.captureOnAction) {
          _replayCapture?.requestCapture();
        }
      }
    } on Object catch (error, stackTrace) {
      reportDiagnostic(
        _configuration.onError,
        'RUM action recording failed',
        error,
        stackTrace,
      );
    }
  }

  void _recordError(
    Object error, {
    StackTrace? stackTrace,
    required List<RumStackFrame> frames,
    required RumContext context,
    required String source,
  }) {
    if (_stopped) return;
    try {
      final RumSession? session = _prepareSession();
      if (session == null || !session.sampled) return;
      final error_description.ErrorDescription details = error_description
          .describeError(
            error,
            stackTrace,
            platform: _configuration.platform,
            debugId: _configuration.debugId,
          );
      final List<Map<String, Object?>> serializedFrames = <RumStackFrame>[
        ...frames,
        ...details.stack,
      ].take(100).map(_sanitizeFrame).toList(growable: false);
      final String signature = <String>[
        details.type,
        details.message,
        ...serializedFrames
            .take(3)
            .map((Map<String, Object?> frame) => frame.toString()),
      ].join('|');
      final int nowMilliseconds = DateTime.now().millisecondsSinceEpoch;
      final int? previous = _recentErrors[signature];
      if (previous != null && nowMilliseconds - previous < 1000) return;
      _recentErrors[signature] = nowMilliseconds;
      _pruneRecentErrors(nowMilliseconds);

      final int timestamp = nowMicros();
      _visualChangeId += 1;
      _sessionManager.recordError(session, crash: source == 'platform');
      final String fingerprint = 'fp_${fnv1a(signature)}';
      final RumContext errorContext = _compact(<String, Object?>{
        ...sanitizeContext(_globalContext),
        ...sanitizeContext(context),
        'source': source,
        if (_currentViewPath.isNotEmpty) 'page': _currentViewPath,
      });
      final RumContext event = _compact(<String, Object?>{
        ..._commonFields(timestamp, session),
        'timestamp': timestamp,
        'session_id': session.id,
        'user_id': _currentUserId,
        'fingerprint': fingerprint,
        'message': details.message,
        if (_currentViewPath.isNotEmpty) 'page': _currentViewPath,
        if (_currentViewPath.isNotEmpty) 'url': _currentViewPath,
        'application': _configuration.applicationId,
        'environment': _configuration.env,
        'version': _configuration.version,
        'release': _configuration.version,
        'service': _configuration.service,
        'error_type': details.type,
        'error': _compact(<String, Object?>{
          'type': details.type,
          'message': details.message,
          'stack': serializedFrames,
          if (_configuration.defaultPrivacyLevel == RumPrivacyLevel.allow)
            'raw_stack': details.rawStack,
          'context': errorContext,
        }),
        'context': errorContext,
      });
      _enqueue(RumEventKind.error, event);
      _recordAction(
        _ActionInput(
          type: 'error',
          name: details.message,
          timestampMicros: timestamp,
          context: <String, Object?>{
            'fingerprint': fingerprint,
            'error_type': details.type,
            'source': source,
          },
        ),
      );
    } on Object catch (recordingError, recordingStack) {
      reportDiagnostic(
        _configuration.onError,
        'RUM error recording failed',
        recordingError,
        recordingStack,
      );
    }
  }

  RumSession? _prepareSession() {
    if (_stopped) return null;
    final SessionResult result = _sessionManager.ensure();
    for (final RumSession closed in result.closedSessions) {
      _reportFinalSession(closed);
    }
    if (result.created) {
      _replayOverride = null;
      _recentErrors.clear();
    }
    _syncReplayCapture(result.session);
    if (result.session.sampled && !result.session.reported) {
      _reportSessionStart(result.session);
    }
    return result.session;
  }

  void _reportRecoveredSessions() {
    for (final RumSession session in _sessionManager.pendingFinalizations()) {
      _reportFinalSession(session);
    }
  }

  void _syncReplayCapture(RumSession session) {
    final RumReplayCapture? capture = _replayCapture;
    if (capture == null) return;
    if (_isReplayEnabled(session)) {
      capture.start(session.id, _acceptReplayCapture, _markVisualChange);
    } else {
      capture.stop();
    }
  }

  void _acceptReplayCapture(String sessionId, RumContext event) {
    if (_stopped) return;
    final RumSession session = _sessionManager.active();
    if (session.id != sessionId || !_isReplayEnabled(session)) {
      return;
    }
    final RumContext? prepared = _applyReplayBeforeSend(
      _withReplayBuildMetadata(event),
    );
    if (prepared != null) {
      _eventTransport.enqueueReplay(session.id, prepared);
    }
  }

  void _recordReplay(RumSession session, RumContext event) {
    if (!_isReplayEnabled(session)) return;
    final RumContext? prepared = _applyReplayBeforeSend(
      _withReplayBuildMetadata(event),
    );
    if (prepared != null) {
      _eventTransport.enqueueReplay(session.id, prepared);
    }
  }

  bool _isReplayEnabled(RumSession session) {
    if (!session.sampled) return false;
    final bool? override = _replayOverride;
    return override ?? session.replaySampled;
  }

  void _markVisualChange() {
    _visualChangeId += 1;
  }

  void _reportSessionStart(RumSession session) {
    final int timestamp = session.startedAtMicros;
    final RumContext event = _compact(<String, Object?>{
      ..._commonFields(timestamp, session),
      'timestamp': timestamp,
      'session_id': session.id,
      'user_id': _currentUserId,
      'started_at': timestamp,
      'started_at_micros': timestamp,
      'phase': 'start',
      'application': _configuration.applicationId,
      'app_version': _configuration.version,
      'environment': _configuration.env,
      'version': _configuration.version,
      'service': _configuration.service,
      if (session.landingPage != null || _currentViewPath.isNotEmpty)
        'landing_page': session.landingPage ?? _currentViewPath,
      if (session.lastPage != null || _currentViewPath.isNotEmpty)
        'last_page': session.lastPage ?? _currentViewPath,
      if (_user != null) 'user': sanitizeContext(_user!.toJson()),
      'context': sanitizeContext(_globalContext),
    });
    if (_enqueue(RumEventKind.session, event)) {
      _sessionManager.markReported(session.id);
    }
  }

  void _reportFinalSession(RumSession session) {
    if (session.finalReported) return;
    if (!session.sampled) {
      _sessionManager.markFinalReported(session.id);
      return;
    }
    final int timestamp = session.endedAtMicros ?? session.lastActivityMicros;
    final RumContext event = _compact(<String, Object?>{
      ..._commonFields(timestamp, session),
      'timestamp': timestamp,
      'session_id': session.id,
      'phase': 'end',
      'started_at': session.startedAtMicros,
      'started_at_micros': session.startedAtMicros,
      'ended_at_micros': timestamp,
      'last_activity_micros': session.lastActivityMicros,
      'duration_us': session.durationMicros,
      'duration_ms': session.durationMicros / 1000,
      'view_count': session.viewCount,
      'action_count': session.actionCount,
      'error_count': session.errorCount,
      'resource_count': session.resourceCount,
      'crashed': session.crashed,
      'end_reason': session.endReason ?? 'unknown',
      if (session.landingPage != null) 'landing_page': session.landingPage,
      if (session.lastPage != null) 'last_page': session.lastPage,
      if (_user != null) 'user': sanitizeContext(_user!.toJson()),
      'context': sanitizeContext(_globalContext),
    });
    if (_enqueue(RumEventKind.session, event)) {
      _sessionManager.markFinalReported(session.id);
    }
  }

  RumContext _commonFields(int timestamp, RumSession session) =>
      _compact(<String, Object?>{
        'timestamp': timestamp,
        'session_id': session.id,
        'session_sequence': _sessionManager.nextEventSequence(session.id),
        'application': _configuration.applicationId,
        'environment': _configuration.env,
        'version': _configuration.version,
        'service': _configuration.service,
        'platform': _configuration.platform,
        'architecture': _configuration.architecture,
        'debug_id': _configuration.debugId,
        'framework': 'flutter',
        'runtime': 'flutter',
        'user_id': _currentUserId,
        'anonymous_id': _anonymousUserId,
        'browser': _environment['browser'],
        'os': _environment['os'],
        'device': _environment['device'],
        'language': _environment['language'],
        'timezone': _environment['timezone'],
        'viewport': _environment['viewport'],
        'sdk_name': 'molesignal_flutter',
        'sdk_version': '0.3.0',
      });

  String? get _currentUserId => _user?.id ?? _anonymousUserId;

  bool _enqueue(RumEventKind kind, RumContext event) {
    final RumContext? prepared = _applyBeforeSend(kind, event);
    return prepared != null && _eventTransport.enqueue(kind, prepared);
  }

  RumContext? _applyBeforeSend(RumEventKind kind, RumContext event) {
    final RumBeforeSend? beforeSend = _configuration.beforeSend;
    if (beforeSend != null) {
      try {
        if (beforeSend(event, RumBeforeSendContext(kind)) == false) return null;
      } on Object catch (error, stackTrace) {
        reportDiagnostic(
          _configuration.onError,
          'RUM beforeSend failed',
          error,
          stackTrace,
        );
      }
    }
    return sanitizeContext(event);
  }

  RumContext? _applyReplayBeforeSend(RumContext event) {
    final RumBeforeSend? beforeSend = _configuration.beforeSend;
    if (beforeSend == null) return sanitizeReplayContext(event);
    try {
      final bool dropped =
          beforeSend(event, const RumBeforeSendContext(RumEventKind.replay)) ==
          false;
      return dropped ? null : sanitizeReplayContext(event);
    } on Object catch (error, stackTrace) {
      reportDiagnostic(
        _configuration.onError,
        'RUM beforeSend failed',
        error,
        stackTrace,
      );
      return sanitizeReplayContext(event);
    }
  }

  RumContext _withReplayBuildMetadata(RumContext event) {
    final RumContext result = <String, Object?>{
      ...event,
      'application': _configuration.applicationId,
      'service': _configuration.service,
      'version': _configuration.version,
      'platform': _configuration.platform,
      'architecture': _configuration.architecture,
      'debug_id': _configuration.debugId,
    };
    if (event['type'] == 4 && event['data'] is Map<dynamic, dynamic>) {
      result['data'] = <String, Object?>{
        ...(event['data']! as Map<dynamic, dynamic>).map(
          (dynamic key, dynamic value) =>
              MapEntry<String, Object?>(key.toString(), value),
        ),
        'application': _configuration.applicationId,
        'service': _configuration.service,
        'version': _configuration.version,
        'platform': _configuration.platform,
        'architecture': _configuration.architecture,
        'debug_id': _configuration.debugId,
      };
    }
    return result;
  }

  void _pruneRecentErrors(int nowMilliseconds) {
    if (_recentErrors.length < 100) return;
    _recentErrors.removeWhere(
      (String _, int timestamp) => nowMilliseconds - timestamp > 60000,
    );
  }

  Map<String, Object?> _sanitizeFrame(RumStackFrame frame) {
    final RumArtifactKind artifactKind = _configuration.platform == 'flutter'
        ? RumArtifactKind.javascriptSourcemap
        : frame.artifactKind;
    return _compact(<String, Object?>{
      'artifact_kind': artifactKind.wireName,
      if (frame.module != null) 'module': _frameModule(frame.module!),
      if (frame.function != null)
        'function': sanitizeText(frame.function!, limit: 1024),
      if (frame.file != null) 'file': sanitizeStackFile(frame.file!),
      if (frame.line != null) 'line': frame.line! < 1 ? 1 : frame.line,
      if (frame.column != null) 'column': frame.column! < 1 ? 1 : frame.column,
      if (_configuration.platform != 'flutter')
        'instruction_addr': _frameAddress(frame.instructionAddress),
      if (_configuration.platform != 'flutter')
        'image_addr': _frameAddress(frame.imageAddress),
      if (_configuration.platform != 'flutter')
        'relative_address': _frameAddress(frame.relativeAddress),
      'debug_id': sanitizeText(
        frame.debugId ?? _configuration.debugId,
        limit: 128,
      ),
    });
  }

  String _frameModule(String value) {
    final String safe = sanitizeStackFile(value).replaceAll('\\', '/');
    final int slash = safe.lastIndexOf('/');
    return sanitizeText(
      slash < 0 ? safe : safe.substring(slash + 1),
      limit: 256,
    );
  }

  String? _frameAddress(String? value) {
    final String normalized = value?.trim().toLowerCase() ?? '';
    if (normalized.isEmpty) return null;
    final String digits = normalized.startsWith('0x')
        ? normalized.substring(2)
        : normalized;
    if (!RegExp(r'^[0-9a-f]+$').hasMatch(digits)) return null;
    final int? parsed = int.tryParse(digits, radix: 16);
    return parsed == null ? null : '0x${parsed.toRadixString(16)}';
  }
}

final class _ActionInput {
  const _ActionInput({
    required this.type,
    this.name,
    this.url,
    this.durationMs,
    this.durationUs,
    this.status,
    this.timestampMicros,
    this.traceContext,
    this.context = const <String, Object?>{},
  });

  final String type;
  final String? name;
  final String? url;
  final double? durationMs;
  final int? durationUs;
  final int? status;
  final int? timestampMicros;
  final RumTraceContext? traceContext;
  final RumContext context;
}

final class _InteractionSample {
  const _InteractionSample(this.timestampMicros, this.x, this.y);

  factory _InteractionSample.fromContext(int timestamp, RumContext context) {
    final Object? x = context['x'];
    final Object? y = context['y'];
    return _InteractionSample(
      timestamp,
      x is num ? x.toDouble() : null,
      y is num ? y.toDouble() : null,
    );
  }

  final int timestampMicros;
  final double? x;
  final double? y;

  bool isNear(Offset position) {
    if (x == null || y == null) return true;
    return (Offset(x!, y!) - position).distance <= 18;
  }
}

const int _maximumSafeJsonInteger = 9007199254740991;

bool _validEpochMicros(int value) =>
    value > 0 && value <= _maximumSafeJsonInteger;

bool _validMetricValue(num value) {
  final double converted = value.toDouble();
  return converted.isFinite && converted.abs() <= _maximumSafeJsonInteger;
}

RumContext _compact(RumContext value) {
  value.removeWhere((String _, Object? entry) => entry == null);
  return value;
}
