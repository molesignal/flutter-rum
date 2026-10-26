import 'dart:collection';

import '../models.dart';

final RegExp _sensitiveKey = RegExp(
  r'(?:password|passwd|secret|token|authorization|cookie|set-cookie|api[-_]?key|credit[-_]?card|cvv)',
  caseSensitive: false,
);

final RegExp _rumCredential = RegExp(
  r'\bmsrum_[A-Za-z0-9]{16}_[A-Za-z0-9]{32}\b',
);
final RegExp _bearerCredential = RegExp(
  r'\bBearer\s+[^\s,;]+',
  caseSensitive: false,
);
final RegExp _authorizationAssignment = RegExp(
  r'\b(?:authorization|client[_-]?token|api[_-]?key)\s*[:=]\s*[^\s,;]+',
  caseSensitive: false,
);
final RegExp _absoluteUnixPath = RegExp(
  r'(?<![A-Za-z0-9+.-])/(?:Users|home|private|var|tmp)/[^\s\)]+',
);
final RegExp _absoluteWindowsPath = RegExp(
  r'\b[A-Za-z]:\\(?:Users|Documents and Settings|Temp)\\[^\s\)]+',
  caseSensitive: false,
);

RumContext sanitizeContext(Object? value) {
  final Object? sanitized = _sanitizeValue(
    value,
    0,
    HashSet<Object>.identity(),
    false,
  );
  if (sanitized is Map<String, Object?>) return sanitized;
  return <String, Object?>{};
}

RumContext sanitizeReplayContext(Object? value) {
  final Object? sanitized = _sanitizeValue(
    value,
    0,
    HashSet<Object>.identity(),
    true,
  );
  return sanitized is Map<String, Object?> ? sanitized : <String, Object?>{};
}

/// Keys whose string values are stack text and may exceed the default limit.
const Set<String> _stackTextKeys = <String>{'stack', 'handling_stack'};

/// Objects whose keys are names the application chose for a timing or a feature
/// flag, and whose values are numbers or flag results. A name such as
/// `token_refreshed` is not a secret, and replacing its value would also break
/// the integer the contract requires for a timing.
const Set<String> _namedValueObjects = <String>{
  'custom_timings',
  'feature_flags',
};

Object? _sanitizeValue(
  Object? value,
  int depth,
  Set<Object> seen,
  bool preserveReplayImages, [
  String? key,
]) {
  if (value == null || value is bool || value is int) return value;
  if (value is String) {
    if (preserveReplayImages &&
        value.startsWith('data:image/png;base64,') &&
        value.length <= 8 * 1024 * 1024) {
      return value;
    }
    return sanitizeText(
      value,
      limit: _stackTextKeys.contains(key) ? 32768 : 4096,
    );
  }
  if (value is double) return value.isFinite ? value : value.toString();
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value is Uri) return sanitizeUrlValue(value.toString());
  if (value is StackTrace) return sanitizeStackText(value.toString());
  if (depth >= (preserveReplayImages ? 16 : 6)) return '[Max depth]';

  if (value is Iterable<Object?>) {
    if (seen.contains(value)) return '[Circular]';
    seen.add(value);
    final List<Object?> result = value
        .take(100)
        .map(
          (Object? item) =>
              _sanitizeValue(item, depth + 1, seen, preserveReplayImages, key),
        )
        .toList(growable: false);
    seen.remove(value);
    return result;
  }

  if (value is Map<Object?, Object?>) {
    if (seen.contains(value)) return '[Circular]';
    seen.add(value);
    final String? parentKey = key;
    final RumContext result = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in value.entries.take(100)) {
      final String key = truncate(entry.key.toString(), 256);
      result[key] =
          !_namedValueObjects.contains(parentKey) && _sensitiveKey.hasMatch(key)
          ? '[Redacted]'
          : _sanitizeValue(
              entry.value,
              depth + 1,
              seen,
              preserveReplayImages,
              key,
            );
    }
    seen.remove(value);
    return result;
  }

  return sanitizeText(value.toString(), limit: 4096);
}

/// Removes credentials and embedded URL query strings from arbitrary text.
String sanitizeText(String value, {int limit = 4096}) {
  String result = _redactCredentials(value);
  result = result.replaceAllMapped(
    RegExp(r'https?://[^\s\]\[\)\(<>]+', caseSensitive: false),
    (Match match) => sanitizeUrlValue(match.group(0)!),
  );
  return truncate(result, limit);
}

/// Sanitizes a URL even when query collection is enabled. Sensitive query
/// values are always redacted and URL credentials are always removed.
String sanitizeUrlValue(String raw, {bool includeQuery = false}) {
  final Uri? parsed = Uri.tryParse(raw.trim());
  if (parsed == null) return truncate(_redactCredentials(raw), 4096);
  if (!parsed.hasAuthority) {
    return truncate(_redactCredentials(raw), 4096);
  }
  final Map<String, List<String>> query = <String, List<String>>{};
  if (includeQuery) {
    for (final MapEntry<String, List<String>> entry
        in parsed.queryParametersAll.entries) {
      query[entry.key] = _sensitiveKey.hasMatch(entry.key)
          ? const <String>['[Redacted]']
          : entry.value
                .map((String item) => sanitizeText(item, limit: 512))
                .toList(growable: false);
    }
  }
  return truncate(
    Uri(
      scheme: parsed.scheme,
      host: parsed.host,
      port: parsed.hasPort ? parsed.port : null,
      path: parsed.path,
      queryParameters: query.isEmpty ? null : query,
    ).toString(),
    4096,
  );
}

String _redactCredentials(String value) => value
    .replaceAll(_rumCredential, '[Redacted]')
    .replaceAll(_bearerCredential, 'Bearer [Redacted]')
    .replaceAll(_authorizationAssignment, '[Redacted]');

/// Removes developer-machine paths and credentials from raw stack text.
String sanitizeStackText(String value) => truncate(
  sanitizeText(value, limit: 32768)
      .replaceAllMapped(
        _absoluteUnixPath,
        (Match match) => sanitizeStackFile(match.group(0)!),
      )
      .replaceAllMapped(
        _absoluteWindowsPath,
        (Match match) => sanitizeStackFile(match.group(0)!),
      ),
  32768,
);

/// Keeps only a package/lib-relative or basename representation of a frame.
String sanitizeStackFile(String value) {
  String result = sanitizeUrlValue(value);
  if (result.startsWith('package:') || result.startsWith('dart:')) {
    return truncate(result, 1024);
  }
  result = result.replaceAll('\\', '/');
  final int libIndex = result.lastIndexOf('/lib/');
  if (libIndex >= 0) return truncate(result.substring(libIndex + 1), 1024);
  final int assetsIndex = result.lastIndexOf('/assets/');
  if (assetsIndex >= 0) {
    return truncate(result.substring(assetsIndex + 1), 1024);
  }
  if (result.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(result)) {
    final int slash = result.lastIndexOf('/');
    return truncate(slash >= 0 ? result.substring(slash + 1) : result, 1024);
  }
  return truncate(result, 1024);
}

String truncate(String value, int limit) =>
    value.length <= limit ? value : '${value.substring(0, limit)}…';
