import 'internal/identifiers.dart';
import 'internal/runtime_build.dart';
import 'models.dart';

/// Screenshot replay controls for Flutter applications.
///
/// Flutter has no DOM. The SDK therefore records privacy-processed screen
/// snapshots and encodes them as rrweb full snapshots plus image mutations so
/// MoleSignal's existing replay player can display them.
final class RumSessionReplayConfiguration {
  const RumSessionReplayConfiguration({
    this.captureInterval = const Duration(seconds: 5),
    this.captureOnAction = true,
    this.pixelRatio = 0.5,
    this.maximumImageDimension = 900,
    this.maskColorValue = 0xFF6B7280,
  });

  /// Interval used to look for visual changes while replay is active.
  final Duration captureInterval;

  /// Capture the next painted frame after a RUM action.
  final bool captureOnAction;

  /// Output pixels per logical Flutter pixel before dimension limiting.
  final double pixelRatio;

  /// Hard limit for the longest encoded image edge.
  final int maximumImageDimension;

  /// ARGB color painted over protected screen regions.
  final int maskColorValue;
}

/// Configuration accepted by [initRum].
final class RumConfiguration {
  const RumConfiguration({
    required this.applicationId,
    required this.clientToken,
    required this.site,
    this.service,
    this.env,
    this.version,
    this.platform,
    this.architecture,
    this.debugId,
    this.user,
    this.globalContext = const <String, Object?>{},
    this.sessionSampleRate = 100,
    this.sessionReplaySampleRate = 0,
    this.sessionReplay = const RumSessionReplayConfiguration(),
    this.trackUserInteractions = false,
    this.trackFrustrations,
    this.trackFlutterErrors = true,
    this.trackPlatformErrors = true,
    this.trackResources = true,
    this.trackAppLifecycle = true,
    this.trackLongTasks = true,
    this.trackLongFrames,
    this.trackViewPerformance = true,
    this.longFrameThreshold = const Duration(milliseconds: 100),
    this.trackAnonymousUser = true,
    this.trackUrlQueryString = false,
    this.defaultPrivacyLevel = RumPrivacyLevel.mask,
    this.excludedUrls = const <Pattern>[],
    this.allowedTracingUrls = const <Pattern>[],
    this.flushInterval = const Duration(seconds: 5),
    this.batchSize = 50,
    this.replayFlushInterval = const Duration(seconds: 10),
    this.replayBatchSize = 100,
    this.maxQueueSize = 1000,
    this.maxQueueBytes = 32 * 1024 * 1024,
    this.queueItemTtl = const Duration(hours: 24),
    this.retryInitialDelay = const Duration(seconds: 1),
    this.retryMaxDelay = const Duration(minutes: 1),
    this.requestTimeout = const Duration(seconds: 15),
    this.flushTimeout = const Duration(seconds: 20),
    this.sessionInactivityTimeout = const Duration(minutes: 30),
    this.maxSessionDuration = const Duration(hours: 4),
    this.actionDeduplicationWindow = const Duration(milliseconds: 300),
    this.frozenFrameThreshold = const Duration(milliseconds: 700),
    this.beforeSend,
    this.onError,
    this.transport,
    this.persistence,
  });

  final String applicationId;
  final String clientToken;
  final String site;
  final String? service;
  final String? env;
  final String? version;

  /// Artifact upload `platform`. Defaults to `android`, `ios`, or `flutter`
  /// (for Flutter Web and unsupported desktop targets).
  final String? platform;

  /// Artifact upload architecture, for example `arm64`, `x86_64`, or
  /// `javascript`. Supply this explicitly for release artifacts.
  final String? architecture;

  /// Stable build identifier shared with `/api/v1/debug-artifacts` uploads.
  /// A deterministic fallback is generated when omitted, but release builds
  /// should provide their CI build ID explicitly.
  final String? debugId;
  final RumUser? user;
  final RumContext globalContext;

  /// Percentage in the inclusive `0..100` range.
  final double sessionSampleRate;

  /// Percentage of sampled sessions that record privacy-processed replay.
  final double sessionReplaySampleRate;
  final RumSessionReplayConfiguration sessionReplay;
  final bool trackUserInteractions;

  /// Defaults to [trackUserInteractions].
  final bool? trackFrustrations;
  final bool trackFlutterErrors;
  final bool trackPlatformErrors;
  final bool trackResources;
  final bool trackAppLifecycle;
  final bool trackLongTasks;

  /// Backwards-compatible alias for [trackLongTasks].
  @Deprecated('Use trackLongTasks instead.')
  final bool? trackLongFrames;

  /// Records Flutter first-render timing for each view.
  final bool trackViewPerformance;
  final Duration longFrameThreshold;
  final bool trackAnonymousUser;
  final bool trackUrlQueryString;
  final RumPrivacyLevel defaultPrivacyLevel;

  /// String patterns use substring matching; regular expressions are supported.
  final List<Pattern> excludedUrls;

  /// Empty means trace response headers are read from every tracked URL.
  final List<Pattern> allowedTracingUrls;

  final Duration flushInterval;
  final int batchSize;
  final Duration replayFlushInterval;
  final int replayBatchSize;
  final int maxQueueSize;
  final int maxQueueBytes;
  final Duration queueItemTtl;
  final Duration retryInitialDelay;
  final Duration retryMaxDelay;
  final Duration requestTimeout;
  final Duration flushTimeout;
  final Duration sessionInactivityTimeout;
  final Duration maxSessionDuration;
  final Duration actionDeduplicationWindow;
  final Duration frozenFrameThreshold;

  final RumBeforeSend? beforeSend;
  final RumDiagnosticHandler? onError;
  final RumTransport? transport;
  final RumPersistence? persistence;
}

/// Validated and bounded configuration used by the implementation.
final class NormalizedRumConfiguration {
  NormalizedRumConfiguration._({
    required this.applicationId,
    required this.clientToken,
    required this.site,
    required this.service,
    required this.env,
    required this.version,
    required this.platform,
    required this.architecture,
    required this.debugId,
    required this.user,
    required this.globalContext,
    required this.sessionSampleRate,
    required this.sessionReplaySampleRate,
    required this.sessionReplay,
    required this.trackUserInteractions,
    required this.trackFrustrations,
    required this.trackFlutterErrors,
    required this.trackPlatformErrors,
    required this.trackResources,
    required this.trackAppLifecycle,
    required this.trackLongFrames,
    required this.trackViewPerformance,
    required this.longFrameThreshold,
    required this.trackAnonymousUser,
    required this.trackUrlQueryString,
    required this.defaultPrivacyLevel,
    required this.excludedUrls,
    required this.allowedTracingUrls,
    required this.flushInterval,
    required this.batchSize,
    required this.replayFlushInterval,
    required this.replayBatchSize,
    required this.maxQueueSize,
    required this.maxQueueBytes,
    required this.queueItemTtl,
    required this.retryInitialDelay,
    required this.retryMaxDelay,
    required this.requestTimeout,
    required this.flushTimeout,
    required this.sessionInactivityTimeout,
    required this.maxSessionDuration,
    required this.actionDeduplicationWindow,
    required this.frozenFrameThreshold,
    required this.beforeSend,
    required this.onError,
    required this.transport,
    required this.persistence,
  });

  factory NormalizedRumConfiguration.from(RumConfiguration config) {
    final String applicationId = _required(
      config.applicationId,
      'applicationId',
    );
    final String clientToken = _required(config.clientToken, 'clientToken');
    if (!RegExp(
      r'^msrum_[A-Za-z0-9]{16}_[A-Za-z0-9]{32}$',
    ).hasMatch(clientToken)) {
      throw ArgumentError.value(
        '[Redacted]',
        'clientToken',
        'must match msrum_<16 alphanumeric>_<32 alphanumeric>',
      );
    }
    if (applicationId.length > 128 ||
        !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(applicationId)) {
      throw ArgumentError.value(
        applicationId,
        'applicationId',
        'must be 1..128 characters using A-Z, a-z, 0-9, dot, underscore, colon, or hyphen',
      );
    }
    final Uri site = _normalizeSite(_required(config.site, 'site'));
    final String service = _optional(config.service) ?? applicationId;
    final String version = _optional(config.version) ?? 'unknown';
    final String platform = _normalizePlatform(
      _optional(config.platform) ?? detectRumPlatform(),
    );
    final String architecture = normalizeRumArchitecture(
      _optional(config.architecture) ?? detectRumArchitecture(),
    );
    final String debugId =
        _optional(config.debugId) ??
        _fallbackDebugId(
          applicationId,
          service,
          version,
          platform,
          architecture,
        );
    final RumUser? user = config.user;
    if (user != null && user.id.trim().isEmpty) {
      throw ArgumentError.value(
        user.id,
        'user.id',
        'must be a non-empty string',
      );
    }

    return NormalizedRumConfiguration._(
      applicationId: applicationId,
      clientToken: clientToken,
      site: site,
      service: service,
      env: _optional(config.env),
      version: version,
      platform: platform,
      architecture: architecture,
      debugId: debugId,
      user: user,
      globalContext: Map<String, Object?>.from(config.globalContext),
      sessionSampleRate: _rate(config.sessionSampleRate, 100),
      sessionReplaySampleRate: _rate(config.sessionReplaySampleRate, 0),
      sessionReplay: _normalizeReplay(config.sessionReplay),
      trackUserInteractions: config.trackUserInteractions,
      trackFrustrations:
          config.trackFrustrations ?? config.trackUserInteractions,
      trackFlutterErrors: config.trackFlutterErrors,
      trackPlatformErrors: config.trackPlatformErrors,
      trackResources: config.trackResources,
      trackAppLifecycle: config.trackAppLifecycle,
      trackLongFrames: config.trackLongFrames ?? config.trackLongTasks,
      trackViewPerformance: config.trackViewPerformance,
      longFrameThreshold: _duration(
        config.longFrameThreshold,
        const Duration(milliseconds: 100),
        const Duration(milliseconds: 16),
        const Duration(seconds: 10),
      ),
      trackAnonymousUser: config.trackAnonymousUser,
      trackUrlQueryString: config.trackUrlQueryString,
      defaultPrivacyLevel: config.defaultPrivacyLevel,
      excludedUrls: List<Pattern>.unmodifiable(config.excludedUrls),
      allowedTracingUrls: List<Pattern>.unmodifiable(config.allowedTracingUrls),
      flushInterval: _duration(
        config.flushInterval,
        const Duration(seconds: 5),
        const Duration(milliseconds: 250),
        const Duration(minutes: 1),
      ),
      batchSize: _clampInt(config.batchSize, 1, 100),
      replayFlushInterval: _duration(
        config.replayFlushInterval,
        const Duration(seconds: 10),
        const Duration(milliseconds: 250),
        const Duration(minutes: 1),
      ),
      replayBatchSize: _clampInt(config.replayBatchSize, 1, 200),
      maxQueueSize: _clampInt(config.maxQueueSize, 20, 10000),
      maxQueueBytes: _clampInt(
        config.maxQueueBytes,
        256 * 1024,
        64 * 1024 * 1024,
      ),
      queueItemTtl: _duration(
        config.queueItemTtl,
        const Duration(hours: 24),
        const Duration(minutes: 1),
        const Duration(days: 7),
      ),
      retryInitialDelay: _duration(
        config.retryInitialDelay,
        const Duration(seconds: 1),
        const Duration(milliseconds: 100),
        const Duration(minutes: 1),
      ),
      retryMaxDelay: _duration(
        config.retryMaxDelay,
        const Duration(minutes: 1),
        const Duration(seconds: 1),
        const Duration(hours: 1),
      ),
      requestTimeout: _duration(
        config.requestTimeout,
        const Duration(seconds: 15),
        const Duration(seconds: 1),
        const Duration(minutes: 2),
      ),
      flushTimeout: _duration(
        config.flushTimeout,
        const Duration(seconds: 20),
        const Duration(seconds: 1),
        const Duration(minutes: 5),
      ),
      sessionInactivityTimeout: _duration(
        config.sessionInactivityTimeout,
        const Duration(minutes: 30),
        const Duration(minutes: 1),
        const Duration(hours: 24),
      ),
      maxSessionDuration: _duration(
        config.maxSessionDuration,
        const Duration(hours: 4),
        const Duration(minutes: 1),
        const Duration(hours: 24),
      ),
      actionDeduplicationWindow: _duration(
        config.actionDeduplicationWindow,
        const Duration(milliseconds: 300),
        const Duration(milliseconds: 50),
        const Duration(seconds: 2),
      ),
      frozenFrameThreshold: _duration(
        config.frozenFrameThreshold,
        const Duration(milliseconds: 700),
        const Duration(milliseconds: 100),
        const Duration(seconds: 10),
      ),
      beforeSend: config.beforeSend,
      onError: config.onError,
      transport: config.transport,
      persistence: config.persistence,
    );
  }

  final String applicationId;
  final String clientToken;
  final Uri site;
  final String service;
  final String? env;
  final String version;
  final String platform;
  final String architecture;
  final String debugId;
  final RumUser? user;
  final RumContext globalContext;
  final double sessionSampleRate;
  final double sessionReplaySampleRate;
  final RumSessionReplayConfiguration sessionReplay;
  final bool trackUserInteractions;
  final bool trackFrustrations;
  final bool trackFlutterErrors;
  final bool trackPlatformErrors;
  final bool trackResources;
  final bool trackAppLifecycle;
  final bool trackLongFrames;
  final bool trackViewPerformance;
  final Duration longFrameThreshold;
  final bool trackAnonymousUser;
  final bool trackUrlQueryString;
  final RumPrivacyLevel defaultPrivacyLevel;
  final List<Pattern> excludedUrls;
  final List<Pattern> allowedTracingUrls;
  final Duration flushInterval;
  final int batchSize;
  final Duration replayFlushInterval;
  final int replayBatchSize;
  final int maxQueueSize;
  final int maxQueueBytes;
  final Duration queueItemTtl;
  final Duration retryInitialDelay;
  final Duration retryMaxDelay;
  final Duration requestTimeout;
  final Duration flushTimeout;
  final Duration sessionInactivityTimeout;
  final Duration maxSessionDuration;
  final Duration actionDeduplicationWindow;
  final Duration frozenFrameThreshold;
  final RumBeforeSend? beforeSend;
  final RumDiagnosticHandler? onError;
  final RumTransport? transport;
  final RumPersistence? persistence;

  Uri endpoint(RumEventKind kind) {
    String path = site.path.replaceFirst(RegExp(r'/+$'), '');
    final String suffix = switch (kind) {
      RumEventKind.session => 'sessions',
      RumEventKind.action => 'actions',
      RumEventKind.error => 'errors',
      RumEventKind.replay => 'replay',
    };
    if (path.endsWith('/api/v1/rum')) {
      path = '$path/$suffix';
    } else if (path.endsWith('/api/v1')) {
      path = '$path/rum/$suffix';
    } else if (path.endsWith('/api')) {
      path = '$path/v1/rum/$suffix';
    } else {
      path = '$path/api/v1/rum/$suffix';
    }
    return site.replace(path: path.replaceAll(RegExp('/{2,}'), '/'));
  }
}

RumSessionReplayConfiguration _normalizeReplay(
  RumSessionReplayConfiguration value,
) => RumSessionReplayConfiguration(
  captureInterval: _duration(
    value.captureInterval,
    const Duration(seconds: 5),
    const Duration(milliseconds: 250),
    const Duration(minutes: 10),
  ),
  captureOnAction: value.captureOnAction,
  pixelRatio: value.pixelRatio.isFinite
      ? value.pixelRatio.clamp(0.1, 2).toDouble()
      : 0.5,
  maximumImageDimension: _clampInt(value.maximumImageDimension, 240, 1200),
  maskColorValue: value.maskColorValue,
);

String _required(String value, String field) {
  final String result = value.trim();
  if (result.isEmpty) {
    throw ArgumentError.value(value, field, 'must be a non-empty string');
  }
  return result;
}

String? _optional(String? value) {
  final String result = value?.trim() ?? '';
  return result.isEmpty ? null : result;
}

Uri _normalizeSite(String value) {
  final Uri? parsed = Uri.tryParse(value);
  if (parsed == null || !parsed.hasScheme || !parsed.hasAuthority) {
    throw ArgumentError.value(value, 'site', 'must be an absolute http(s) URL');
  }
  if (parsed.scheme != 'http' && parsed.scheme != 'https') {
    throw ArgumentError.value(value, 'site', 'must use http or https');
  }
  if (parsed.userInfo.isNotEmpty || parsed.hasQuery || parsed.hasFragment) {
    throw ArgumentError.value(
      value,
      'site',
      'must not contain credentials, a query, or a fragment',
    );
  }
  return Uri(
    scheme: parsed.scheme,
    host: parsed.host,
    port: parsed.hasPort ? parsed.port : null,
    path: parsed.path.replaceFirst(RegExp(r'/+$'), ''),
  );
}

String _normalizePlatform(String value) {
  final String platform = value.trim().toLowerCase();
  if (platform == 'android' || platform == 'ios' || platform == 'flutter') {
    return platform;
  }
  throw ArgumentError.value(
    value,
    'platform',
    'must be android, ios, or flutter',
  );
}

String _fallbackDebugId(
  String application,
  String service,
  String version,
  String platform,
  String architecture,
) {
  final String seed = '$application|$service|$version|$platform|$architecture';
  return 'auto-${fnv1a(seed)}-${fnv1a('$seed|molesignal')}';
}

double _rate(double value, double fallback) {
  if (!value.isFinite) return fallback;
  return value.clamp(0, 100).toDouble();
}

int _clampInt(int value, int minimum, int maximum) {
  if (value < minimum) return minimum;
  if (value > maximum) return maximum;
  return value;
}

Duration _duration(
  Duration value,
  Duration fallback,
  Duration minimum,
  Duration maximum,
) {
  if (value == Duration.zero) return fallback;
  if (value < minimum) return minimum;
  if (value > maximum) return maximum;
  return value;
}
