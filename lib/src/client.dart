import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'configuration.dart';
import 'environment/default_device_info.dart';
import 'environment/device_info.dart';
import 'events/action_scope.dart';
import 'events/event_bodies.dart';
import 'events/event_context.dart';
import 'events/frame_json.dart';
import 'events/frame_moments.dart';
import 'events/pending.dart';
import 'events/view_scope.dart';
import 'instrumentation/flutter_instrumentation.dart';
import 'instrumentation/sink.dart';
import 'internal/diagnostics.dart';
import 'internal/error_description.dart' as error_description;
import 'internal/identifiers.dart';
import 'internal/runtime_info.dart';
import 'internal/sanitization.dart';
import 'internal/transport_error.dart';
import 'internal/units.dart';
import 'internal/urls.dart';
import 'models.dart';
import 'persistence.dart';
import 'replay/capture.dart';
import 'rum_client.dart';
import 'session/identity.dart';
import 'session/session_manager.dart';
import 'transport/event_transport.dart';

/// An action stays open this long after the last thing it caused.
const Duration _actionQuietPeriod = Duration(milliseconds: 100);

/// An action never stays open longer than this, however slow its requests.
const Duration _maximumActionDuration = Duration(seconds: 5);

/// Taps this close together, this many times within a second, are a rage tap.
const double _rageTapDistance = 50;
const int _rageTapCount = 3;

/// Same-signature errors closer together than this are reported once.
const int _errorDeduplicationMillis = 1000;

const Duration _memorySampleInterval = Duration(seconds: 1);

/// Flutter implementation of the MoleSignal RUM client.
final class MoleSignalRumClient implements RumClient, RumInstrumentationSink {
  MoleSignalRumClient._({
    required NormalizedRumConfiguration configuration,
    required SessionManager sessionManager,
    required EventTransport eventTransport,
    required RumDeviceInfoProvider deviceInfo,
    required String? anonymousUserId,
    required int startedAtMicros,
  }) : _configuration = configuration,
       _sessionManager = sessionManager,
       _eventTransport = eventTransport,
       _deviceInfo = deviceInfo,
       _startedAtMicros = startedAtMicros,
       _context = EventContext(
         configuration: configuration,
         deviceInfo: deviceInfo,
         anonymousUserId: anonymousUserId,
       );

  static Future<MoleSignalRumClient> create(
    RumConfiguration configuration,
  ) async {
    final int startedAtMicros = nowMicros();
    WidgetsFlutterBinding.ensureInitialized();
    final NormalizedRumConfiguration normalized =
        NormalizedRumConfiguration.from(configuration);
    final RumPersistence persistence =
        normalized.persistence ?? SharedPreferencesRumPersistence();
    await validateCredentialApplicationBinding(normalized, persistence);
    final SessionManager sessionManager = await SessionManager.create(
      normalized,
      persistence,
      startedAtMicros: startedAtMicros,
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
    final RumDeviceInfoProvider deviceInfo =
        normalized.deviceInfoProvider ??
        createDefaultDeviceInfoProvider(usePlugins: normalized.trackDeviceInfo);
    try {
      await deviceInfo.refresh().timeout(const Duration(milliseconds: 500));
    } on Object {
      // Device context is best effort; events go out without it.
    }
    final MoleSignalRumClient client = MoleSignalRumClient._(
      configuration: normalized,
      sessionManager: sessionManager,
      eventTransport: eventTransport,
      deviceInfo: deviceInfo,
      anonymousUserId: anonymousUserId,
      startedAtMicros: startedAtMicros,
    );
    client._start();
    return client;
  }

  final NormalizedRumConfiguration _configuration;
  final SessionManager _sessionManager;
  final EventTransport _eventTransport;
  final RumDeviceInfoProvider _deviceInfo;
  final int _startedAtMicros;

  /// The identity and device context events carry, and their envelope.
  final EventContext _context;

  late final FlutterRumInstrumentation _instrumentation;
  ViewScope? _view;

  /// The view to show again when the app returns to the foreground.
  ViewScope? _resumeView;
  ActionScope? _action;
  final Map<String, PendingResource> _resources = <String, PendingResource>{};
  final Map<String, PendingVital> _vitals = <String, PendingVital>{};
  final List<TapSample> _taps = <TapSample>[];
  TapSample? _lastExplicitTap;
  final Map<String, int> _recentErrors = <String, int>{};
  RumReplayCapture? _replayCapture;
  bool? _replayOverride;
  bool _startupRecorded = false;
  int _lastMemorySampleMicros = 0;
  bool _stopped = false;
  bool _stopCompleted = false;
  Future<RumFlushResult>? _stopFuture;

  @visibleForTesting
  SessionManager get sessionManager => _sessionManager;

  bool get resourceTrackingEnabled =>
      !_stopped && _configuration.trackResources;

  bool get userInteractionTrackingEnabled =>
      !_stopped && _configuration.trackUserInteractions;

  bool get frustrationTrackingEnabled =>
      !_stopped && _configuration.trackFrustrations;

  RumPrivacyLevel get privacyLevel => _configuration.defaultPrivacyLevel;

  RumSessionReplayConfiguration get replayConfiguration =>
      _configuration.sessionReplay;

  RumDiagnosticHandler? get diagnosticHandler => _configuration.onError;

  String get replayPage {
    final String path = _view?.url ?? '';
    return 'molesignal://flutter${path.startsWith('/') ? path : '/$path'}';
  }

  void _start() {
    _context.inForeground = _lifecycleIsForeground(
      SchedulerBinding.instance.lifecycleState,
    );
    _eventTransport.onFlushTick = _reportDirtyView;
    _eventTransport.start();
    _instrumentation = FlutterRumInstrumentation(_configuration, this)..start();
    _scheduleStartup();
  }

  // Identity and context ------------------------------------------------------

  @override
  void setUser(RumUser user) {
    final String id = user.id.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(user.id, 'user.id', 'must be non-empty');
    }
    _context.user = RumUser(
      id: id,
      name: user.name,
      email: user.email,
      attributes: sanitizeContext(user.attributes),
    );
    _view?.dirty = true;
  }

  @override
  void clearUser() {
    _context.user = null;
    _view?.dirty = true;
  }

  @override
  RumUser? getUser() {
    final RumUser? user = _context.user;
    if (user == null) return null;
    return RumUser(
      id: user.id,
      name: user.name,
      email: user.email,
      attributes: Map<String, Object?>.from(user.attributes),
    );
  }

  @override
  void setAccount(RumAccount account) {
    final String id = account.id.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(account.id, 'account.id', 'must be non-empty');
    }
    _context.account = RumAccount(
      id: id,
      name: account.name,
      attributes: sanitizeContext(account.attributes),
    );
    _view?.dirty = true;
  }

  @override
  void clearAccount() {
    _context.account = null;
    _view?.dirty = true;
  }

  @override
  RumAccount? getAccount() {
    final RumAccount? account = _context.account;
    if (account == null) return null;
    return RumAccount(
      id: account.id,
      name: account.name,
      attributes: Map<String, Object?>.from(account.attributes),
    );
  }

  @override
  void setGlobalContext(RumContext context) {
    _context.globalContext = sanitizeContext(context);
    _view?.dirty = true;
  }

  @override
  void setGlobalContextProperty(String key, Object? value) {
    final String normalized = key.trim();
    if (normalized.isEmpty) return;
    _context.globalContext[normalized] = value;
    _view?.dirty = true;
  }

  @override
  void removeGlobalContextProperty(String key) {
    _context.globalContext.remove(key);
    _view?.dirty = true;
  }

  @override
  void clearGlobalContext() {
    _context.globalContext = <String, Object?>{};
    _view?.dirty = true;
  }

  @override
  RumContext getGlobalContext() => sanitizeContext(_context.globalContext);

  @override
  void addFeatureFlagEvaluation(String name, Object? value) {
    final String key = name.trim();
    if (key.isEmpty || _stopped) return;
    final Map<String, Object?> flags = _context.featureFlags;
    if (!flags.containsKey(key) && flags.length >= 100) return;
    flags[key] = value;
    _view?.dirty = true;
  }

  // Views ---------------------------------------------------------------------

  @override
  void startView(
    String key, {
    String? name,
    RumContext context = const <String, Object?>{},
  }) {
    final String viewKey = key.trim();
    if (viewKey.isEmpty || _stopped) return;
    final String viewName = name?.trim().isNotEmpty == true
        ? name!.trim()
        : viewKey;
    final RumSession? session = _prepareSession();
    if (session == null || !session.sampled) return;
    final ViewScope? current = _view;
    if (current != null &&
        current.active &&
        current.session.id == session.id &&
        current.key == viewKey &&
        current.name == viewName &&
        current.timeSpent <= _configuration.actionDeduplicationWindow) {
      return;
    }
    _resumeView = null;
    _completeAction();
    if (current != null) _endView(current);
    _beginView(
      key: viewKey,
      name: viewName,
      session: session,
      context: context,
    );
  }

  @override
  void stopView(String key) {
    final ViewScope? view = _view;
    if (_stopped || view == null || !view.active || view.key != key.trim()) {
      return;
    }
    _resumeView = null;
    _completeAction();
    _endView(view);
  }

  @override
  void addTiming(String name) {
    if (_stopped) return;
    final ViewScope? view = _view;
    if (view == null || !view.active) return;
    view.addTiming(name);
  }

  ViewScope _beginView({
    required String key,
    required String name,
    required RumSession session,
    String loadingType = 'view_controller_display',
    RumContext context = const <String, Object?>{},
  }) {
    // A view that ended and then received late events (an error while the app
    // was in the background) has changes the receiver has not seen.
    final ViewScope? previous = _view;
    if (previous != null && previous.dirty) _reportView(previous);
    final String url = sanitizeUrl(key, _configuration.trackUrlQueryString);
    final ViewScope view = ViewScope(
      key: key,
      name: name,
      url: url.isEmpty ? '/' : url,
      session: session,
      loadingType: loadingType,
      context: sanitizeContext(context),
    );
    _view = view;
    _sampleMemory(view, force: true);
    _reportView(view);
    _scheduleFirstBuild(view);
    _requestReplayCapture(session);
    return view;
  }

  void _endView(ViewScope view) {
    if (!view.active) return;
    _sampleMemory(view, force: true);
    view.stop();
    _reportView(view);
  }

  /// The view events of [session] belong to, started when there is none.
  /// A view never spans sessions: when the session was renewed under it, the
  /// old view ends and the same screen continues in a new one.
  ViewScope _currentView(RumSession session) {
    final ViewScope? existing = _view;
    if (existing == null) {
      return _beginView(
        key: 'ApplicationLaunch',
        name: 'ApplicationLaunch',
        session: session,
      );
    }
    if (existing.session.id == session.id) return existing;
    _completeAction();
    final bool wasActive = existing.active;
    _endView(existing);
    return _beginView(
      key: existing.key,
      name: existing.name,
      session: session,
      loadingType: wasActive ? 'session_renewal' : 'view_controller_display',
      context: existing.context,
    );
  }

  void _reportView(ViewScope view) {
    final RumSession session = view.session;
    if (!session.sampled) return;
    final RumContext body = view.report();
    _emit(
      RumEventKind.view,
      _context.wrap(
        RumEventKind.view,
        date: view.startedAtMillis,
        view: view,
        body: body,
        context: view.context,
      ),
    );
  }

  void _reportDirtyView() {
    if (_stopped) return;
    final ViewScope? view = _view;
    if (view == null || !view.dirty) return;
    if (view.active) _sampleMemory(view, force: true);
    _reportView(view);
  }

  void _sampleMemory(ViewScope view, {bool force = false}) {
    if (!_configuration.trackViewPerformance) return;
    final int now = nowMicros();
    if (!force &&
        now - _lastMemorySampleMicros < _memorySampleInterval.inMicroseconds) {
      return;
    }
    _lastMemorySampleMicros = now;
    final int? bytes = currentMemoryBytes();
    if (bytes != null) view.sampleMemory(bytes);
  }

  // Actions -------------------------------------------------------------------

  @override
  void addAction(
    String name, {
    RumActionType type = RumActionType.custom,
    RumContext context = const <String, Object?>{},
  }) {
    final String normalized = name.trim();
    if (normalized.isEmpty || _stopped) return;
    _startAction(
      ActionScope(
        type: type.wireName,
        name: normalized,
        nameSource: 'custom_attribute',
        context: context,
      ),
    );
  }

  /// A tap on the screen. [explicit] taps come from `RumUserAction` and carry
  /// the developer's name; automatic ones from `RumApp` and are named
  /// generically so no screen content is read. Only automatic taps depend on
  /// `trackUserInteractions`.
  void recordTap({
    required String name,
    required Offset position,
    required bool explicit,
    Size? targetSize,
    RumContext context = const <String, Object?>{},
  }) {
    if (_stopped || (!explicit && !userInteractionTrackingEnabled)) return;
    final int now = nowMillis();
    final TapSample sample = TapSample(now, position);
    if (explicit) {
      _lastExplicitTap = sample;
    } else {
      final TapSample? previous = _lastExplicitTap;
      if (previous != null &&
          now - previous.millis <=
              _configuration.actionDeduplicationWindow.inMilliseconds &&
          (previous.position - position).distance <= 18) {
        return;
      }
    }
    final List<String> frustrations = <String>[
      if (_configuration.trackFrustrations && _isRageTap(sample)) 'rage_tap',
    ];
    _startAction(
      ActionScope(
        type: 'tap',
        name: name,
        nameSource: explicit ? 'custom_attribute' : 'mask_placeholder',
        selector: explicit ? 'flutter:$name' : 'flutter:interactive',
        position: (x: position.dx.round(), y: position.dy.round()),
        targetWidth: targetSize?.width.round(),
        targetHeight: targetSize?.height.round(),
        frustrations: frustrations,
        context: context,
      ),
      position: position,
    );
  }

  /// A system back gesture or button press.
  @override
  void recordBack() {
    if (!userInteractionTrackingEnabled) return;
    _startAction(ActionScope(type: 'back', name: 'Back'));
  }

  bool _isRageTap(TapSample tap) {
    _taps.removeWhere((TapSample item) => item.millis < tap.millis - 1000);
    _taps.add(tap);
    final int nearby = _taps
        .where(
          (TapSample item) =>
              (item.position - tap.position).distance <= _rageTapDistance,
        )
        .length;
    if (nearby < _rageTapCount) return false;
    _taps.clear();
    return true;
  }

  void _startAction(ActionScope scope, {Offset? position}) {
    try {
      final RumSession? session = _prepareSession();
      if (session == null || !session.sampled) return;
      final ViewScope view = _currentView(session);
      _completeAction();
      _action = scope;
      _scheduleActionCheck(scope);
      _recordReplayPointer(session, position);
      _requestReplayCapture(session);
      view.dirty = true;
    } on Object catch (error, stackTrace) {
      reportDiagnostic(
        _configuration.onError,
        'RUM action recording failed',
        error,
        stackTrace,
      );
    }
  }

  void _scheduleActionCheck(ActionScope scope) {
    scope.timer?.cancel();
    scope.timer = Timer(_actionQuietPeriod, () {
      if (!identical(_action, scope)) return;
      final bool waiting =
          scope.elapsed < _maximumActionDuration &&
          (scope.pendingResources > 0 || scope.quietFor < _actionQuietPeriod);
      if (waiting) {
        _scheduleActionCheck(scope);
      } else {
        _completeAction();
      }
    });
  }

  /// Emits the open action, if any, with what it caused so far.
  void _completeAction() {
    final ActionScope? scope = _action;
    if (scope == null) return;
    _action = null;
    scope.timer?.cancel();
    scope.timer = null;
    final ViewScope? view = _view;
    if (view == null || !view.session.sampled) return;
    try {
      if (scope.isTap &&
          scope.errorCount > 0 &&
          _configuration.trackFrustrations) {
        scope.addFrustration('error_tap');
      }
      view.actionCount += 1;
      view.frustrationCount += scope.frustrations.length;
      view.dirty = true;
      _emit(
        RumEventKind.action,
        _context.wrap(
          RumEventKind.action,
          date: scope.startedAtMillis,
          view: view,
          body: actionBody(scope),
          context: scope.context,
        ),
      );
    } on Object catch (error, stackTrace) {
      reportDiagnostic(
        _configuration.onError,
        'RUM action recording failed',
        error,
        stackTrace,
      );
    }
  }

  // Resources -----------------------------------------------------------------

  @override
  void startResource(
    String key,
    String method,
    Uri url, {
    RumContext context = const <String, Object?>{},
  }) {
    if (!_trackable(url)) return;
    // A request that never ends (a response body nobody reads) must neither
    // pile up nor hold its action open for good.
    final PendingResource? replaced = _resources.remove(key);
    _forget(replaced ?? (_resources.length >= 256 ? _oldestResource() : null));
    final ActionScope? action = _action;
    action?.pendingResources += 1;
    action?.touch();
    _resources[key] = PendingResource(
      method: method,
      url: url,
      action: action,
      context: context,
    );
  }

  PendingResource? _oldestResource() {
    if (_resources.isEmpty) return null;
    return _resources.remove(_resources.keys.first);
  }

  void _forget(PendingResource? pending) {
    final ActionScope? action = pending?.action;
    if (action != null && pending!.counted) {
      action.pendingResources = max(0, action.pendingResources - 1);
    }
  }

  @override
  void stopResource(
    String key, {
    int? statusCode,
    int? size,
    RumTraceContext? traceContext,
    RumContext context = const <String, Object?>{},
  }) {
    final PendingResource? pending = _resources.remove(key);
    if (pending == null) return;
    _finishResource(
      pending,
      statusCode: statusCode,
      size: size,
      traceContext: traceContext,
      context: context,
    );
  }

  @override
  void stopResourceWithError(
    String key,
    Object error, {
    int? statusCode,
    RumTraceContext? traceContext,
    RumContext context = const <String, Object?>{},
  }) {
    final PendingResource? pending = _resources.remove(key);
    if (pending == null) return;
    _finishResource(
      pending,
      statusCode: statusCode,
      failure: error,
      traceContext: traceContext,
      context: context,
    );
  }

  @override
  void addResource(RumResource resource) {
    if (!_trackable(resource.url)) return;
    if (resource.duration.isNegative ||
        (resource.responseSize != null && resource.responseSize! < 0)) {
      reportDiagnostic(
        _configuration.onError,
        'RUM resource dropped: invalid duration or size',
      );
      return;
    }
    final DateTime start =
        resource.startTime ?? DateTime.now().subtract(resource.duration);
    final ActionScope? action = _action;
    _finishResource(
      PendingResource(
        method: resource.method,
        url: resource.url,
        action:
            action != null &&
                start.millisecondsSinceEpoch >= action.startedAtMillis
            ? action
            : null,
        context: resource.context,
        startedAtMillis: start.millisecondsSinceEpoch,
        duration: resource.duration,
        counted: false,
      ),
      statusCode: resource.statusCode,
      size: resource.responseSize,
      traceContext: resource.traceContext,
      failureType: resource.errorType,
      failureCode: resource.errorCode,
      failureMessage: resource.errorMessage,
    );
  }

  bool _trackable(Uri url) =>
      resourceTrackingEnabled && !isSdkUrl(url) && shouldTrackUrl(url);

  void _finishResource(
    PendingResource pending, {
    int? statusCode,
    int? size,
    RumTraceContext? traceContext,
    Object? failure,
    String? failureType,
    String? failureCode,
    String? failureMessage,
    RumContext context = const <String, Object?>{},
  }) {
    final ActionScope? action = pending.action;
    if (action != null && pending.counted) {
      action.pendingResources = max(0, action.pendingResources - 1);
    }
    try {
      final RumSession? session = _prepareSession();
      if (session == null || !session.sampled) return;
      final ViewScope view = _currentView(session);
      final bool attributed = action != null && identical(_action, action);
      if (attributed) {
        action.resourceCount += 1;
        action.touch();
      }
      final NormalizedTransportError? failed = failure != null
          ? normalizeTransportError(failure)
          : (failureType == null &&
                    failureCode == null &&
                    failureMessage == null
                ? null
                : NormalizedTransportError(
                    failureType ?? 'connection',
                    failureCode ?? failureType ?? 'connection_failed',
                    failureMessage ?? '',
                  ));
      final String url = sanitizeUrl(
        pending.url.toString(),
        _configuration.trackUrlQueryString,
      );
      final String method = pending.method.trim().toUpperCase();
      final int? status = failed == null ? statusCode : (statusCode ?? 0);
      view.resourceCount += 1;
      view.dirty = true;
      _emit(
        RumEventKind.resource,
        _context.wrap(
          RumEventKind.resource,
          date: pending.startedAtMillis,
          view: view,
          actionId: action?.id,
          body: resourceBody(
            method: method,
            url: url,
            duration: pending.duration ?? pending.elapsed,
            statusCode: status,
            size: size,
            traceContext: traceContext,
          ),
          context: <String, Object?>{...pending.context, ...context},
        ),
      );
      if (failed != null && failed.type != 'cancel') {
        _recordError(
          NetworkFailure(
            failed.message.isEmpty
                ? '$method $url failed'
                : '$method $url failed: ${failed.message}',
          ),
          source: RumErrorSource.network,
          handling: 'handled',
          type: failed.code,
          category: 'Network',
          resource: <String, Object?>{
            if (httpMethodOrNull(method) != null) 'method': method,
            'status_code': 0,
            'url': url,
          },
          includeStack: false,
          dedupe: false,
        );
      }
    } on Object catch (error, stackTrace) {
      reportDiagnostic(
        _configuration.onError,
        'RUM resource recording failed',
        error,
        stackTrace,
      );
    }
  }

  // Errors --------------------------------------------------------------------

  @override
  void addError(
    Object error, {
    StackTrace? stackTrace,
    RumErrorSource source = RumErrorSource.custom,
    String? type,
    String? fingerprint,
    List<RumStackFrame> frames = const <RumStackFrame>[],
    RumContext context = const <String, Object?>{},
  }) {
    _recordError(
      error,
      stackTrace: stackTrace,
      frames: frames,
      context: context,
      source: source,
      handling: 'handled',
      type: type,
      fingerprint: fingerprint,
    );
  }

  @override
  void recordCapturedError(
    Object error, {
    StackTrace? stackTrace,
    RumContext meta = const <String, Object?>{},
    required bool fatal,
  }) {
    _recordError(
      error,
      stackTrace: stackTrace,
      source: RumErrorSource.source,
      handling: 'unhandled',
      isCrash: fatal,
      meta: meta,
    );
  }

  void _recordError(
    Object error, {
    StackTrace? stackTrace,
    List<RumStackFrame> frames = const <RumStackFrame>[],
    RumContext context = const <String, Object?>{},
    required RumErrorSource source,
    required String handling,
    String? type,
    String? fingerprint,
    bool isCrash = false,
    String category = 'Exception',
    RumContext? resource,
    RumContext meta = const <String, Object?>{},
    bool includeStack = true,
    bool dedupe = true,
  }) {
    if (_stopped) return;
    try {
      final RumSession? session = _prepareSession();
      if (session == null || !session.sampled) return;
      final error_description.ErrorDescription details = error_description
          .describeError(
            error,
            includeStack ? stackTrace : StackTrace.empty,
            platform: _configuration.platform,
            debugId: _configuration.debugId,
          );
      final List<RumStackFrame> allFrames = <RumStackFrame>[
        ...frames,
        ...details.frames,
      ].take(100).toList(growable: false);
      final List<RumContext> serializedFrames = allFrames
          .map(
            (RumStackFrame frame) => frameJson(
              frame,
              native: _configuration.platform != 'flutter',
              debugId: _configuration.debugId,
            ),
          )
          .toList(growable: false);
      if (dedupe && _isRecentDuplicate(details, serializedFrames)) return;

      final ViewScope view = _currentView(session);
      final ActionScope? action = _action;
      if (action != null) {
        action.errorCount += 1;
        if (isCrash) action.crashCount += 1;
        action.touch();
      }
      view.errorCount += 1;
      if (isCrash) view.crashCount += 1;
      view.dirty = true;
      final bool rawStackAllowed =
          _configuration.defaultPrivacyLevel == RumPrivacyLevel.allow;
      _emit(
        RumEventKind.error,
        _context.wrap(
          RumEventKind.error,
          date: nowMillis(),
          view: view,
          actionId: action?.id,
          body: errorBody(
            message: details.message,
            source: source,
            handling: handling,
            type: type ?? details.type,
            stack: includeStack
                ? (rawStackAllowed
                      ? details.stackText
                      : error_description.renderFrames(allFrames))
                : null,
            frames: serializedFrames,
            fingerprint: fingerprint,
            isCrash: isCrash,
            category: category,
            resource: resource,
            wasTruncated: details.wasTruncated,
            meta: meta,
          ),
          context: context,
        ),
      );
      _requestReplayCapture(session);
      if (isCrash) {
        // The process may not survive: send the crash and the view's new
        // crash count now.
        _reportDirtyView();
        unawaited(_eventTransport.flush());
      }
    } on Object catch (recordingError, recordingStack) {
      reportDiagnostic(
        _configuration.onError,
        'RUM error recording failed',
        recordingError,
        recordingStack,
      );
    }
  }

  bool _isRecentDuplicate(
    error_description.ErrorDescription details,
    List<RumContext> frames,
  ) {
    final String signature = <String>[
      details.type,
      details.message,
      ...frames.take(3).map((RumContext frame) => frame.toString()),
    ].join('|');
    final int now = nowMillis();
    final int? previous = _recentErrors[signature];
    if (previous != null && now - previous < _errorDeduplicationMillis) {
      return true;
    }
    _recentErrors[signature] = now;
    if (_recentErrors.length >= 100) {
      _recentErrors.removeWhere((String _, int time) => now - time > 60000);
    }
    return false;
  }

  // Vitals --------------------------------------------------------------------

  @override
  void startDurationVital(
    String name, {
    String? description,
    RumContext context = const <String, Object?>{},
  }) {
    final String key = name.trim();
    if (key.isEmpty || _stopped) return;
    _vitals[key] = PendingVital(description: description, context: context);
  }

  @override
  void stopDurationVital(
    String name, {
    String? description,
    RumContext context = const <String, Object?>{},
  }) {
    final String key = name.trim();
    final PendingVital? pending = _vitals.remove(key);
    if (pending == null || _stopped) return;
    _recordVital(
      key,
      pending.elapsed,
      startedAtMillis: pending.startedAtMillis,
      description: description ?? pending.description,
      context: <String, Object?>{...pending.context, ...context},
    );
  }

  @override
  void addDurationVital(
    String name,
    Duration duration, {
    String? description,
    RumContext context = const <String, Object?>{},
  }) {
    final String key = name.trim();
    if (key.isEmpty || duration.isNegative || _stopped) return;
    _recordVital(
      key,
      duration,
      startedAtMillis: nowMillis() - duration.inMilliseconds,
      description: description,
      context: context,
    );
  }

  void _recordVital(
    String name,
    Duration duration, {
    required int startedAtMillis,
    String? description,
    required RumContext context,
  }) {
    try {
      final RumSession? session = _prepareSession();
      if (session == null || !session.sampled) return;
      final ViewScope view = _currentView(session);
      _emit(
        RumEventKind.vital,
        _context.wrap(
          RumEventKind.vital,
          date: startedAtMillis,
          view: view,
          body: durationVitalBody(
            name: name,
            duration: duration,
            description: description,
          ),
          context: context,
        ),
      );
    } on Object catch (error, stackTrace) {
      reportDiagnostic(
        _configuration.onError,
        'RUM vital recording failed',
        error,
        stackTrace,
      );
    }
  }

  // Frames and startup --------------------------------------------------------

  @override
  void recordFrameTimings(List<FrameTiming> timings) {
    if (_stopped || timings.isEmpty) return;
    final int deliveredAt = nowMicros();
    final int latestRasterFinish = timings
        .map(
          (FrameTiming t) =>
              t.timestampInMicroseconds(ui.FramePhase.rasterFinish),
        )
        .reduce(max);
    for (final FrameTiming timing in timings) {
      _recordFrame(
        timing,
        frameStartMicros(
          timing,
          deliveredAtMicros: deliveredAt,
          latestRasterFinish: latestRasterFinish,
        ),
      );
    }
  }

  /// One frame, for callers that do not have a batch.
  void recordFrameTiming(FrameTiming timing) =>
      recordFrameTimings(<FrameTiming>[timing]);

  void _recordFrame(FrameTiming timing, int startMicros) {
    if (_stopped) return;
    try {
      final RumSession? session = _sessionManager.live();
      final ViewScope? view = _view;
      if (session == null ||
          !session.sampled ||
          view == null ||
          view.session.id != session.id) {
        return;
      }
      if (view.active && _configuration.trackViewPerformance) {
        view.frames.add(
          timing,
          displayRefreshRate: _displayRefreshRate(),
          frozenThreshold: _configuration.frozenFrameThreshold,
        );
        view.dirty = true;
        _sampleMemory(view);
      }
      final bool frozen =
          timing.totalSpan >= _configuration.frozenFrameThreshold;
      if (_configuration.trackLongTasks &&
          (frozen || timing.totalSpan >= _configuration.longFrameThreshold)) {
        _recordLongTask(view, timing, startMicros, frozen: frozen);
      }
    } on Object catch (error, stackTrace) {
      reportDiagnostic(
        _configuration.onError,
        'RUM frame recording failed',
        error,
        stackTrace,
      );
    }
  }

  void _recordLongTask(
    ViewScope view,
    FrameTiming timing,
    int startMicros, {
    required bool frozen,
  }) {
    view.longTaskCount += 1;
    if (frozen) view.frozenFrameCount += 1;
    view.dirty = true;
    // Timings are reported in batches, and some engines cannot date a frame
    // exactly; a long task is never dated outside the view it happened in.
    final int start = min(
      max(startMicros, view.startedAtMicros),
      view.startedAtMicros + view.timeSpent.inMicroseconds,
    );
    _emit(
      RumEventKind.longTask,
      _context.wrap(
        RumEventKind.longTask,
        date: start ~/ 1000,
        view: view,
        body: longTaskBody(
          duration: timing.totalSpan,
          startNanoseconds: nanosecondsOfMicroseconds(
            start - view.startedAtMicros,
          ),
          frozen: frozen,
        ),
      ),
    );
  }

  /// The end of the first frame built for [view] is its first build complete.
  void _scheduleFirstBuild(ViewScope view) {
    if (!_configuration.trackViewPerformance) return;
    _afterNextFrame((Duration _) {
      if (_stopped || !view.active || view.firstBuildNanoseconds != null) {
        return;
      }
      view.firstBuildNanoseconds = view.elapsedNanoseconds;
      view.dirty = true;
    });
  }

  /// Measures the cold start at the end of the first frame built for the
  /// application's own UI. Frames before `runApp` draw nothing, so the
  /// measurement waits for the root widget.
  void _scheduleStartup() {
    if (!_configuration.trackViewPerformance) return;
    int frames = 0;
    void onFrame(Duration _) {
      if (_stopped || _startupRecorded) return;
      if (WidgetsBinding.instance.rootElement == null && (frames += 1) < 600) {
        WidgetsBinding.instance.addPostFrameCallback(onFrame);
        return;
      }
      _recordStartup(nowMicros());
    }

    _afterNextFrame(onFrame);
  }

  void _afterNextFrame(FrameCallback callback) {
    try {
      WidgetsBinding.instance
        ..addPostFrameCallback(callback)
        ..ensureVisualUpdate();
    } on Object {
      // Without a binding there is no frame to wait for.
    }
  }

  /// The first frame drawn after the SDK started is the cold start: an
  /// `application_start` action and an `app_launch` vital for the time to
  /// initial display.
  void _recordStartup(int atMicros) {
    if (_startupRecorded || !_configuration.trackViewPerformance) return;
    _startupRecorded = true;
    final int ttid = nanosecondsOfMicroseconds(atMicros - _startedAtMicros);
    if (ttid > nanosecondsOf(const Duration(minutes: 10))) return;
    final RumSession? session = _prepareSession();
    if (session == null || !session.sampled) return;
    final ViewScope view = _currentView(session);
    final ActionScope launch = ActionScope(
      type: 'application_start',
      name: 'ApplicationStart',
      fixedLoadingNanoseconds: ttid,
    );
    view.actionCount += 1;
    view.dirty = true;
    _emit(
      RumEventKind.action,
      _context.wrap(
        RumEventKind.action,
        date: _startedAtMicros ~/ 1000,
        view: view,
        body: actionBody(launch),
      ),
    );
    _emit(
      RumEventKind.vital,
      _context.wrap(
        RumEventKind.vital,
        date: _startedAtMicros ~/ 1000,
        view: view,
        body: appLaunchVitalBody(ttidNanoseconds: ttid),
      ),
    );
  }

  double _displayRefreshRate() {
    try {
      final Iterable<ui.FlutterView> views =
          WidgetsBinding.instance.platformDispatcher.views;
      if (views.isNotEmpty) {
        final double rate = views.first.display.refreshRate;
        if (rate.isFinite && rate >= 30 && rate <= 360) return rate;
      }
    } on Object {
      // Fall back to the common refresh rate.
    }
    return 60;
  }

  // Lifecycle -----------------------------------------------------------------

  @override
  void handleLifecycleState(AppLifecycleState state) {
    if (_stopped) return;
    if (_lifecycleIsForeground(state)) {
      if (_context.inForeground) return;
      _context.inForeground = true;
      unawaited(_deviceInfo.refresh());
      final ViewScope? resume = _resumeView;
      _resumeView = null;
      if (resume != null) _showAgain(resume);
      return;
    }
    if (state == AppLifecycleState.inactive) return;
    // paused, hidden, or detached: the app is no longer on screen.
    _context.inForeground = false;
    _completeAction();
    final ViewScope? view = _view;
    if (view != null && view.active) {
      _resumeView = view;
      _endView(view);
    }
    unawaited(flush());
  }

  void _showAgain(ViewScope view) {
    final RumSession? session = _prepareSession();
    if (session == null || !session.sampled) return;
    _beginView(
      key: view.key,
      name: view.name,
      session: session,
      loadingType: view.session.id == session.id
          ? 'view_controller_redisplay'
          : 'session_renewal',
      context: view.context,
    );
  }

  bool _lifecycleIsForeground(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  // Instrumentation helpers ---------------------------------------------------

  bool isSdkUrl(Uri url) => _eventTransport.isSdkUrl(url);

  bool shouldTrackUrl(Uri url) =>
      !matchesUrl(url.toString(), _configuration.excludedUrls);

  bool shouldReadTrace(Uri url) =>
      _configuration.allowedTracingUrls.isEmpty ||
      matchesUrl(url.toString(), _configuration.allowedTracingUrls);

  @override
  RumInternalContext getInternalContext() {
    final RumSession session = _sessionManager.current();
    final ViewScope? view = _view;
    return RumInternalContext(
      applicationId: _configuration.applicationId,
      sessionId: session.sampled ? session.id : null,
      viewId: session.sampled && view?.session.id == session.id
          ? view?.id
          : null,
      userId: _context.userId,
      service: _configuration.service,
      environment: _configuration.env,
      version: _configuration.version,
      buildId: _configuration.debugId,
    );
  }

  // Session replay ------------------------------------------------------------

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

  void _syncReplayCapture(RumSession session) {
    final RumReplayCapture? capture = _replayCapture;
    if (capture == null) return;
    if (_isReplayEnabled(session)) {
      capture.start(session.id, _acceptReplayCapture);
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
    if (prepared != null &&
        _eventTransport.enqueueReplay(session.id, prepared)) {
      if (!session.replayRecorded) {
        _sessionManager.markReplayRecorded(session.id);
        // The next report of the view tells the receiver the session has a
        // replay.
        _view?.dirty = true;
      }
    }
  }

  void _recordReplayPointer(RumSession session, Offset? position) {
    if (position == null || !_isReplayEnabled(session)) return;
    _replayCapture?.recordPointer(position, timestampMilliseconds: nowMillis());
  }

  void _requestReplayCapture(RumSession session) {
    if (_configuration.sessionReplay.captureOnAction &&
        _isReplayEnabled(session)) {
      _replayCapture?.requestCapture();
    }
  }

  bool _isReplayEnabled(RumSession session) {
    if (!session.sampled) return false;
    final bool? override = _replayOverride;
    return override ?? session.replaySampled;
  }

  // Shutdown ------------------------------------------------------------------

  @override
  Future<RumFlushResult> flush() async {
    _completeAction();
    _reportDirtyView();
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
      _completeAction();
      final ViewScope? view = _view;
      if (view != null) _endView(view);
      await _sessionManager.persistNow();
      _stopped = true;
      _resources.clear();
      _vitals.clear();
      _replayCapture?.stop();
      _instrumentation.stop();
      await _deviceInfo.close();
      return await _eventTransport.stop();
    } finally {
      _stopCompleted = true;
    }
  }

  // Events --------------------------------------------------------------------

  bool _emit(RumEventKind kind, RumContext event) {
    final RumContext? prepared = _applyBeforeSend(kind, event);
    return prepared != null && _eventTransport.enqueue(prepared);
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

  RumSession? _prepareSession() {
    if (_stopped) return null;
    final SessionResult result = _sessionManager.resolve();
    if (result.created) {
      _replayOverride = null;
      _recentErrors.clear();
      _taps.clear();
      if (!result.session.sampled) {
        // Nothing of the new session is recorded, so the view of the old one
        // is not renewed; close it under its own session.
        _completeAction();
        final ViewScope? old = _view;
        if (old != null) _endView(old);
      }
    }
    _syncReplayCapture(result.session);
    return result.session;
  }
}
