/// JSON-compatible custom dimensions attached to RUM events.
typedef RumContext = Map<String, Object?>;

/// Controls whether raw error stacks may be uploaded.
enum RumPrivacyLevel { mask, allow }

/// Debug artifact type used to symbolicate a structured stack frame
/// (`error.frames[].artifact_kind`).
enum RumArtifactKind {
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
/// [column]; obfuscated AOT frames carry addresses instead and name the
/// [artifactKind] that resolves them. Flutter Web frames have no artifact kind:
/// their source map is selected by [file] and [debugId].
final class RumStackFrame {
  const RumStackFrame({
    this.artifactKind,
    this.module,
    this.className,
    this.function,
    this.file,
    this.line,
    this.column,
    this.instructionAddress,
    this.imageAddress,
    this.relativeAddress,
    this.debugId,
    this.buildId,
  });

  final RumArtifactKind? artifactKind;
  final String? module;
  final String? className;
  final String? function;
  final String? file;
  final int? line;
  final int? column;
  final String? instructionAddress;
  final String? imageAddress;
  final String? relativeAddress;

  /// Build identity shared with `/api/v1/debug-artifacts` uploads. Defaults to
  /// `RumConfiguration.debugId`.
  final String? debugId;

  /// Build identifier reported by the runtime itself, for example the `build_id`
  /// in a Dart AOT stack trace header.
  final String? buildId;

  RumContext toJson() => <String, Object?>{
    if (artifactKind != null) 'artifact_kind': artifactKind!.wireName,
    if (module != null) 'module': module,
    if (className != null) 'class': className,
    if (function != null) 'function': function,
    if (file != null) 'file': file,
    if (line != null) 'line': line,
    if (column != null) 'column': column,
    if (instructionAddress != null) 'instruction_addr': instructionAddress,
    if (imageAddress != null) 'image_addr': imageAddress,
    if (relativeAddress != null) 'relative_address': relativeAddress,
    if (debugId != null) 'debug_id': debugId,
    if (buildId != null) 'build_id': buildId,
  };
}

/// The kind of a user action (`action.type`). The automatic
/// `application_start` action is not user-selectable.
enum RumActionType {
  tap('tap'),
  click('click'),
  scroll('scroll'),
  swipe('swipe'),
  back('back'),
  custom('custom');

  const RumActionType(this.wireName);

  final String wireName;
}

/// Where an error came from (`error.source`).
enum RumErrorSource {
  source('source'),
  network('network'),
  console('console'),
  logger('logger'),
  agent('agent'),
  webview('webview'),
  custom('custom'),
  report('report');

  const RumErrorSource(this.wireName);

  final String wireName;
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

  /// Events (or replay events) the receiver confirmed.
  final int accepted;

  /// Events that failed with a retryable error and stay queued.
  final int retried;

  /// Events discarded, including those the receiver rejected.
  final int dropped;
  final int remaining;
  final bool timedOut;

  /// Drop counts by reason: `queue_full`, `expired`, `non_retryable`,
  /// `rejected` (the receiver refused the event), and a few others.
  final Map<String, int> dropReasons;
}

/// The event types of the MoleSignal event contract, plus session replay.
///
/// [wireName] is the contract's `type` value.
enum RumEventKind {
  view('view'),
  action('action'),
  error('error'),
  resource('resource'),
  longTask('long_task'),
  vital('vital'),
  replay('replay');

  const RumEventKind(this.wireName);

  final String wireName;
}

/// The receiver endpoint a [RumTransportRequest] is addressed to.
enum RumUploadKind {
  /// `POST /api/v1/rum/events`: a JSON array of contract events.
  events('events'),

  /// `POST /api/v1/rum/replay`: one replay segment.
  replay('replay');

  const RumUploadKind(this.wireName);

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

/// The account (organization, workspace, tenant) the user acts on behalf of.
final class RumAccount {
  const RumAccount({
    required this.id,
    this.name,
    this.attributes = const <String, Object?>{},
  });

  final String id;
  final String? name;
  final RumContext attributes;

  RumContext toJson() => <String, Object?>{
    ...attributes,
    'id': id,
    if (name != null) 'name': name,
  };
}

/// Context supplied to [RumBeforeSend].
final class RumBeforeSendContext {
  const RumBeforeSendContext(this.kind);

  final RumEventKind kind;
}

/// Runs immediately before an event is queued.
///
/// The callback may mutate [event], which has the shape of the event contract
/// (replay events are rrweb records). Returning `false` drops the event.
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
    this.compress = false,
  });

  final Uri url;

  /// The uncompressed JSON body.
  final String body;
  final Map<String, String> headers;
  final RumUploadKind kind;

  /// Whether the transport should send [body] with `Content-Encoding: gzip`
  /// when it can.
  final bool compress;
}

/// Response returned by a custom [RumTransport].
///
/// For `events` uploads [body] is the receiver's
/// `{"accepted": n, "rejected": [{"index": i, "reason": "..."}]}` answer, and
/// [headers] (lower-case names) may carry `retry-after`.
final class RumTransportResponse {
  const RumTransportResponse({
    required this.ok,
    required this.status,
    this.statusText,
    this.body,
    this.headers = const <String, String>{},
  });

  final bool ok;
  final int status;
  final String? statusText;
  final String? body;
  final Map<String, String> headers;
}

/// Upload adapter used for application-owned intake proxies and tests.
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

/// W3C trace identifiers correlated with a network resource.
///
/// [traceId] is the 32-hex trace; [spanId] the 16-hex span carried by the
/// `traceparent` that was found. Both are lower-case.
final class RumTraceContext {
  const RumTraceContext({required this.traceId, required this.spanId});

  final String traceId;
  final String spanId;
}

/// Public context that can be forwarded to logs or traces created by the app.
final class RumInternalContext {
  const RumInternalContext({
    required this.applicationId,
    this.sessionId,
    this.viewId,
    this.userId,
    this.service,
    this.environment,
    this.version,
    this.buildId,
  });

  final String applicationId;
  final String? sessionId;
  final String? viewId;
  final String? userId;
  final String? service;
  final String? environment;
  final String? version;
  final String? buildId;

  RumContext toJson() => <String, Object?>{
    'application_id': applicationId,
    if (sessionId != null) 'session_id': sessionId,
    if (viewId != null) 'view_id': viewId,
    if (userId != null) 'user_id': userId,
    if (service != null) 'service': service,
    if (environment != null) 'env': environment,
    if (version != null) 'version': version,
    if (buildId != null) 'build_id': buildId,
  };
}

/// A network request that has already finished, reported with
/// `MoleSignalRumClient.addResource`.
///
/// Use `startResource` / `stopResource` instead when the request should be
/// attributed to the user action that triggered it.
final class RumResource {
  const RumResource({
    required this.method,
    required this.url,
    required this.duration,
    this.startTime,
    this.statusCode,
    this.responseSize,
    this.traceContext,
    this.errorType,
    this.errorCode,
    this.errorMessage,
    this.context = const <String, Object?>{},
  });

  final String method;
  final Uri url;
  final Duration duration;

  /// Defaults to the moment the resource is reported minus [duration].
  final DateTime? startTime;

  /// `null` or `0` when the request failed before a response arrived.
  final int? statusCode;
  final int? responseSize;
  final RumTraceContext? traceContext;

  /// Set when no response arrived. [errorType] is a coarse class (`timeout`,
  /// `dns`, `tls`, `cancel`, `connection`) and [errorCode] a stable detail.
  /// A failed request produces a `network` error; a cancelled one does not.
  final String? errorType;
  final String? errorCode;
  final String? errorMessage;
  final RumContext context;
}
