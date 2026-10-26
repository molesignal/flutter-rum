import '../internal/sanitization.dart';
import '../models.dart';

/// The contract's `error.frames[]` entry for [frame], sanitized.
///
/// Flutter Web frames ([native] is `false`) are resolved by file through a
/// source map; they have no native image to address and no artifact kind.
/// A frame without its own `debug_id` carries [debugId], the build identity
/// debug artifacts are uploaded under.
Map<String, Object?> frameJson(
  RumStackFrame frame, {
  required bool native,
  required String debugId,
}) {
  final String? module = frame.module;
  final String? className = frame.className;
  final String? function = frame.function;
  final String? file = frame.file;
  final int? line = frame.line;
  final int? column = frame.column;
  final String? buildId = frame.buildId;
  return <String, Object?>{
    if (native) 'artifact_kind': ?frame.artifactKind?.wireName,
    'module': ?(module == null ? null : _frameModule(module)),
    'class': ?(className == null ? null : sanitizeText(className, limit: 1024)),
    'function': ?(function == null
        ? null
        : sanitizeText(function, limit: 1024)),
    'file': ?(file == null ? null : sanitizeStackFile(file)),
    'line': ?(line == null ? null : (line < 1 ? 1 : line)),
    'column': ?(column == null ? null : (column < 1 ? 1 : column)),
    if (native) 'instruction_addr': ?_frameAddress(frame.instructionAddress),
    if (native) 'image_addr': ?_frameAddress(frame.imageAddress),
    if (native) 'relative_address': ?_frameAddress(frame.relativeAddress),
    'debug_id': sanitizeText(frame.debugId ?? debugId, limit: 128),
    'build_id': ?(buildId == null ? null : sanitizeText(buildId, limit: 128)),
  };
}

String _frameModule(String value) {
  final String safe = sanitizeStackFile(value).replaceAll('\\', '/');
  final int slash = safe.lastIndexOf('/');
  return sanitizeText(slash < 0 ? safe : safe.substring(slash + 1), limit: 256);
}

String? _frameAddress(String? value) {
  final String normalized = value?.trim().toLowerCase() ?? '';
  if (normalized.isEmpty) return null;
  final String digits = normalized.startsWith('0x')
      ? normalized.substring(2)
      : normalized;
  if (!RegExp(r'^[0-9a-f]+$').hasMatch(digits)) return null;
  final BigInt? parsed = BigInt.tryParse(digits, radix: 16);
  return parsed == null ? null : '0x${parsed.toRadixString(16)}';
}
