import '../internal/identifiers.dart';
import '../internal/units.dart';
import '../models.dart';
import 'action_scope.dart';

const Set<String> _httpMethods = <String>{
  'POST',
  'GET',
  'HEAD',
  'PUT',
  'DELETE',
  'PATCH',
  'TRACE',
  'OPTIONS',
  'CONNECT',
};

/// [method] upper-cased when the contract knows it, otherwise `null`.
String? httpMethodOrNull(String method) {
  final String normalized = method.trim().toUpperCase();
  return _httpMethods.contains(normalized) ? normalized : null;
}

final RegExp _traceId = RegExp(r'^[0-9a-f]{16,32}$');
final RegExp _spanId = RegExp(r'^[0-9a-f]{16}$');

/// The `action` body of a finished action.
RumContext actionBody(ActionScope scope) {
  final int? loading = scope.loadingNanoseconds;
  final ({int x, int y})? position = scope.position;
  return <String, Object?>{
    'id': scope.id,
    'type': scope.type,
    'loading_time': ?loading,
    'target': <String, Object?>{
      'name': scope.name,
      if (scope.selector != null) 'selector': scope.selector,
      if (scope.targetWidth != null) 'width': scope.targetWidth,
      if (scope.targetHeight != null) 'height': scope.targetHeight,
    },
    if (position != null)
      'position': <String, Object?>{'x': position.x, 'y': position.y},
    if (scope.nameSource != null) 'name_source': scope.nameSource,
    if (scope.frustrations.isNotEmpty)
      'frustration': <String, Object?>{
        'type': List<String>.of(scope.frustrations),
      },
    'error': <String, Object?>{'count': scope.errorCount},
    'crash': <String, Object?>{'count': scope.crashCount},
    'resource': <String, Object?>{'count': scope.resourceCount},
  };
}

/// The `resource` body of a request. [url] must already be sanitized.
RumContext resourceBody({
  required String method,
  required String url,
  required Duration duration,
  int? statusCode,
  int? size,
  RumTraceContext? traceContext,
}) {
  final String? normalizedMethod = httpMethodOrNull(method);
  final String? traceId = traceContext?.traceId.toLowerCase();
  final String? spanId = traceContext?.spanId.toLowerCase();
  final bool traced =
      traceId != null &&
      spanId != null &&
      _traceId.hasMatch(traceId) &&
      _spanId.hasMatch(spanId);
  return <String, Object?>{
    'id': generateUuid(),
    'type': 'native',
    'method': ?normalizedMethod,
    'url': url,
    'status_code': statusCode == null || statusCode < 0 ? 0 : statusCode,
    'duration': nanosecondsOf(duration),
    if (size != null && size >= 0) 'size': size,
    if (traced) 'trace_id': traceId,
    if (traced) 'span_id': spanId,
  };
}

/// The `error` body.
RumContext errorBody({
  required String message,
  required RumErrorSource source,
  required String handling,
  required String type,
  String? stack,
  List<RumContext> frames = const <RumContext>[],
  String? fingerprint,
  bool isCrash = false,
  String category = 'Exception',
  RumContext? resource,
  bool wasTruncated = false,
  RumContext meta = const <String, Object?>{},
}) => <String, Object?>{
  'id': generateUuid(),
  'message': message,
  'source': source.wireName,
  'type': type,
  'handling': handling,
  if (stack != null && stack.isNotEmpty) 'stack': stack,
  if (frames.isNotEmpty) 'frames': frames,
  if (fingerprint != null && fingerprint.isNotEmpty)
    'fingerprint': fingerprint.length > 128
        ? fingerprint.substring(0, 128)
        : fingerprint,
  'is_crash': isCrash,
  'category': category,
  'source_type': 'flutter',
  'resource': ?resource,
  if (wasTruncated) 'was_truncated': true,
  if (meta.isNotEmpty) 'meta': meta,
};

/// The `long_task` body of a slow or frozen frame.
RumContext longTaskBody({
  required Duration duration,
  required int startNanoseconds,
  required bool frozen,
}) => <String, Object?>{
  'id': generateUuid(),
  'duration': nanosecondsOf(duration),
  'start_time': startNanoseconds < 0 ? 0 : startNanoseconds,
  'is_frozen_frame': frozen,
};

/// A vital measuring a duration of the application's own choosing.
RumContext durationVitalBody({
  required String name,
  required Duration duration,
  String? description,
}) => <String, Object?>{
  'id': generateUuid(),
  'type': 'duration',
  'name': name.length <= 256 ? name : name.substring(0, 256),
  if (description != null && description.isNotEmpty) 'description': description,
  'duration': nanosecondsOf(duration),
};

/// The time to initial display of a cold start.
RumContext appLaunchVitalBody({required int ttidNanoseconds}) =>
    <String, Object?>{
      'id': generateUuid(),
      'type': 'app_launch',
      'app_launch_metric': 'ttid',
      'duration': ttidNanoseconds < 0
          ? 0
          : (ttidNanoseconds > maximumNanoseconds
                ? maximumNanoseconds
                : ttidNanoseconds),
      'startup_type': 'cold_start',
      'is_prewarmed': false,
    };
