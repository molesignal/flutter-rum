/// JSON-compatible custom dimensions attached to RUM events.
typedef RumContext = Map<String, Object?>;

/// Controls whether raw error stacks may be uploaded.
enum RumPrivacyLevel { mask, allow }

/// Debug artifact type used to symbolicate a structured stack frame.
enum RumArtifactKind {
  javascriptSourcemap('javascript_sourcemap'),
  flutterSymbols('flutter_symbols'),
  androidNativeSymbols('android_native_symbols'),
  appleDsym('apple_dsym');

  const RumArtifactKind(this.wireName);

  final String wireName;
}

/// A privacy-safe stack frame that can be matched to an uploaded artifact.
///
/// Native integrations should provide addresses as hexadecimal strings with a
/// `0x` prefix. Dart frames normally only need [function], [file], [line], and
/// [column]; obfuscated AOT integrations can additionally provide addresses.
final class RumStackFrame {
  const RumStackFrame({
    required this.artifactKind,
    this.module,
    this.function,
    this.file,
    this.line,
    this.column,
    this.instructionAddress,
    this.imageAddress,
    this.relativeAddress,
    this.debugId,
  });

  final RumArtifactKind artifactKind;
  final String? module;
  final String? function;
  final String? file;
  final int? line;
  final int? column;
  final String? instructionAddress;
  final String? imageAddress;
  final String? relativeAddress;
  final String? debugId;

  RumContext toJson() => <String, Object?>{
    'artifact_kind': artifactKind.wireName,
    if (module != null) 'module': module,
    if (function != null) 'function': function,
    if (file != null) 'file': file,
    if (line != null) 'line': line,
    if (column != null) 'column': column,
    if (instructionAddress != null) 'instruction_addr': instructionAddress,
    if (imageAddress != null) 'image_addr': imageAddress,
    if (relativeAddress != null) 'relative_address': relativeAddress,
    if (debugId != null) 'debug_id': debugId,
  };
}

/// Stable mobile performance metric names consumed by MoleSignal RUM.
enum RumPerformanceMetricKind {
  coldStart('cold_start'),
  warmStart('warm_start'),
  viewLoad('view_load'),
  slowFrame('slow_frame'),
  frozenFrame('frozen_frame'),
  jank('jank'),
  anr('anr'),
  memory('memory'),
  network('network');

  const RumPerformanceMetricKind(this.wireName);

  final String wireName;
}

/// Unit used by a [RumPerformanceMetric].
enum RumMetricUnit {
  microsecond('microsecond'),
  byte('byte'),
  count('count');

  const RumMetricUnit(this.wireName);

  final String wireName;
}

/// Clock source used to produce a performance value.
enum RumMetricClock {
  monotonic('monotonic'),
  epoch('epoch');

  const RumMetricClock(this.wireName);

  final String wireName;
}

/// A manually supplied performance metric from a platform integration.
final class RumPerformanceMetric {
  const RumPerformanceMetric({
    required this.kind,
    required this.value,
    required this.unit,
    this.clock = RumMetricClock.monotonic,
    this.timestampMicros,
    this.context = const <String, Object?>{},
  });

  final RumPerformanceMetricKind kind;
  final num value;
  final RumMetricUnit unit;
  final RumMetricClock clock;

  /// Epoch microseconds. Durations must stay in [value] and use a monotonic
  /// [clock] instead of deriving them from wall-clock timestamps.
  final int? timestampMicros;
  final RumContext context;
}

/// Outcome of a bounded transport flush or stop operation.
final class RumFlushResult {
  const RumFlushResult({
    this.accepted = 0,
    this.retried = 0,
    this.dropped = 0,
    this.remaining = 0,
    this.timedOut = false,
    this.dropReasons = const <String, int>{},
  });

  final int accepted;
  final int retried;
  final int dropped;
  final int remaining;
  final bool timedOut;
  final Map<String, int> dropReasons;
}

/// The MoleSignal ingestion stream for an event.
enum RumEventKind {
  session('session'),
  action('action'),
  error('error'),
  replay('replay');

  const RumEventKind(this.wireName);

  final String wireName;
}

/// An identified application user plus optional custom attributes.
final class RumUser {
  const RumUser({
    required this.id,
    this.name,
    this.email,
    this.attributes = const <String, Object?>{},
  });

  final String id;
  final String? name;
  final String? email;
  final RumContext attributes;

  RumContext toJson() => <String, Object?>{
    ...attributes,
    'id': id,
    if (name != null) 'name': name,
    if (email != null) 'email': email,
  };
}

/// Context supplied to [RumBeforeSend].
final class RumBeforeSendContext {
  const RumBeforeSendContext(this.kind);

  final RumEventKind kind;
}

/// Runs immediately before an event is queued.
///
/// The callback may mutate [event]. Returning `false` drops the event.
typedef RumBeforeSend =
    bool? Function(RumContext event, RumBeforeSendContext context);

/// A non-fatal SDK diagnostic delivered through `RumConfiguration.onError`.
final class RumDiagnostic implements Exception {
  const RumDiagnostic(this.message, {this.cause, this.stackTrace});

  final String message;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() => 'RumDiagnostic: $message';
}

typedef RumDiagnosticHandler = void Function(RumDiagnostic diagnostic);

/// Request passed to a custom [RumTransport].
final class RumTransportRequest {
  const RumTransportRequest({
    required this.url,
    required this.body,
    required this.headers,
    required this.kind,
  });

  final Uri url;
  final String body;
  final Map<String, String> headers;
  final RumEventKind kind;
}

/// Response returned by a custom [RumTransport].
final class RumTransportResponse {
  const RumTransportResponse({
    required this.ok,
    required this.status,
    this.statusText,
    this.body,
  });

  final bool ok;
  final int status;
  final String? statusText;
  final String? body;
}

/// Upload adapter used for application-owned ingestion proxies and tests.
abstract class RumTransport {
  Future<RumTransportResponse> send(RumTransportRequest request);

  Future<void> close() async {}
}

/// Small key/value persistence abstraction used by sessions and anonymous IDs.
abstract class RumPersistence {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> remove(String key);
}

/// In-memory persistence useful for tests and privacy-sensitive applications.
final class MemoryRumPersistence implements RumPersistence {
  MemoryRumPersistence([Map<String, String>? initialValues])
    : _values = <String, String>{...?initialValues};

  final Map<String, String> _values;

  Map<String, String> get values => Map<String, String>.unmodifiable(_values);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> remove(String key) async {
    _values.remove(key);
  }

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}

/// W3C trace identifiers correlated with a network resource action.
final class RumTraceContext {
  const RumTraceContext({required this.traceId, required this.parentSpanId});

  final String traceId;
  final String parentSpanId;
}

/// Public context that can be forwarded to logs or traces created by the app.
final class RumInternalContext {
  const RumInternalContext({
    required this.applicationId,
    this.sessionId,
    this.userId,
    this.service,
    this.environment,
    this.version,
    this.platform,
    this.architecture,
    this.debugId,
  });

  final String applicationId;
  final String? sessionId;
  final String? userId;
  final String? service;
  final String? environment;
  final String? version;
  final String? platform;
  final String? architecture;
  final String? debugId;

  RumContext toJson() => <String, Object?>{
    'application_id': applicationId,
    if (sessionId != null) 'session_id': sessionId,
    if (userId != null) 'user_id': userId,
    if (service != null) 'service': service,
    if (environment != null) 'env': environment,
    if (version != null) 'version': version,
    if (platform != null) 'platform': platform,
    if (architecture != null) 'architecture': architecture,
    if (debugId != null) 'debug_id': debugId,
  };
}

/// A manually or automatically measured network request.
final class RumResource {
  const RumResource({
    required this.method,
    required this.url,
    required this.duration,
    this.status,
    this.responseSize,
    this.requestSize,
    this.traceContext,
    this.initiator = 'http',
    this.errorType,
    this.errorCode,
    this.errorMessage,
    this.context = const <String, Object?>{},
  });

  final String method;
  final Uri url;
  final Duration duration;
  final int? status;
  final int? responseSize;
  final int? requestSize;
  final RumTraceContext? traceContext;
  final String initiator;
  final String? errorType;
  final String? errorCode;
  final String? errorMessage;
  final RumContext context;
}
