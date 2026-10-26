import '../models.dart';
import 'sanitization.dart';

const int _maximumFrames = 100;

final class ErrorDescription {
  const ErrorDescription({
    required this.type,
    required this.message,
    required this.frames,
    required this.stackText,
    required this.wasTruncated,
  });

  final String type;
  final String message;
  final List<RumStackFrame> frames;

  /// The sanitized stack exactly as the runtime printed it; `null` without a
  /// stack trace.
  final String? stackText;

  /// Frames or text were cut to the SDK's limits.
  final bool wasTruncated;
}

ErrorDescription describeError(
  Object error,
  StackTrace? stackTrace, {
  required String platform,
  required String debugId,
}) {
  final StackTrace? effectiveStack =
      stackTrace ??
      switch (error) {
        final Error value => value.stackTrace,
        _ => null,
      };
  final String? originalStack = effectiveStack?.toString();
  final String type = sanitizeText(error.runtimeType.toString(), limit: 256);
  final String message = sanitizeText(error.toString());
  final List<RumStackFrame> frames = originalStack == null
      ? const <RumStackFrame>[]
      : parseStack(originalStack, platform: platform, debugId: debugId);
  return ErrorDescription(
    type: type,
    message: message.trim().isEmpty ? type : message,
    frames: frames,
    stackText: originalStack == null ? null : sanitizeStackText(originalStack),
    wasTruncated:
        frames.length >= _maximumFrames ||
        (originalStack != null && originalStack.length > 32768),
  );
}

/// The stack as display text rebuilt from sanitized frames, used when raw
/// stack text must not leave the device.
String renderFrames(List<RumStackFrame> frames) {
  final StringBuffer text = StringBuffer();
  for (int index = 0; index < frames.length; index += 1) {
    final RumStackFrame frame = frames[index];
    final String? position = frame.file != null
        ? <String>[
            frame.file!,
            if (frame.line != null) '${frame.line}',
            if (frame.line != null && frame.column != null) '${frame.column}',
          ].join(':')
        : frame.relativeAddress ?? frame.instructionAddress;
    final String? label = frame.function ?? frame.module;
    if (index > 0) text.writeln();
    text.write('    at ');
    if (label != null && position != null) {
      text.write('$label ($position)');
    } else {
      text.write(label ?? position ?? '<unknown>');
    }
  }
  return text.toString();
}

/// Parses a printed stack trace into structured frames.
///
/// Understands the Dart VM's symbolic format (`#0 main (package:app/main.dart:1:2)`),
/// its AOT format with split debug info (`#00 abs … virt …`) together with the
/// header that names the build and the image base, `package:stack_trace`, web
/// (JavaScript) frames, Android native `pc` lines, and Apple crash lines.
List<RumStackFrame> parseStack(
  String stack, {
  required String platform,
  required String debugId,
}) {
  final _AotHeader? aotHeader = _AotHeader.tryParse(stack);
  final List<RumStackFrame> frames = <RumStackFrame>[];
  for (final String rawLine in stack.split('\n')) {
    if (frames.length >= _maximumFrames) break;
    final String line = rawLine.trim();
    if (line.isEmpty || line == '<asynchronous suspension>') continue;
    final RumStackFrame? frame =
        _parseAot(line, aotHeader, debugId) ??
        _parseAndroidNative(line, platform, debugId) ??
        _parseAppleNative(line, platform, debugId) ??
        _parseDart(line, debugId) ??
        _parseWeb(line, debugId) ??
        _parseStackTracePackage(line, debugId);
    if (frame != null) frames.add(frame);
  }
  return frames;
}

/// The header the Dart AOT runtime prints above a non-symbolic stack:
///
/// ```
/// *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
/// build_id: '5d3b4e0a1fe4a0c7a5f3d6e2b1c0a9f8'
/// isolate_dso_base: 78e1c5a000, vm_dso_base: 78e1c5a000
/// ```
final class _AotHeader {
  const _AotHeader({this.buildId, this.isolateDsoBase});

  final String? buildId;
  final BigInt? isolateDsoBase;

  static _AotHeader? tryParse(String stack) {
    final RegExpMatch? build = RegExp(
      r'''build_id:\s*['"]?([0-9a-fA-F]+)['"]?''',
    ).firstMatch(stack);
    final RegExpMatch? base = RegExp(
      r'isolate_dso_base:\s*([0-9a-fA-F]+)',
    ).firstMatch(stack);
    if (build == null && base == null) return null;
    return _AotHeader(
      buildId: build?.group(1)?.toLowerCase(),
      isolateDsoBase: base == null
          ? null
          : BigInt.tryParse(base.group(1)!, radix: 16),
    );
  }
}

/// `#00 abs 0000007a1a3b4d6a1b virt 00000000007d0a1b _kDartIsolateSnapshotInstructions+0x35a1b`
RumStackFrame? _parseAot(String line, _AotHeader? header, String debugId) {
  final RegExpMatch? match = RegExp(
    r'^#\d+\s+abs\s+([0-9a-fA-F]+)(?:\s+virt\s+([0-9a-fA-F]+))?(?:\s+.*)?$',
  ).firstMatch(line);
  if (match == null) return null;
  final BigInt? absolute = BigInt.tryParse(match.group(1)!, radix: 16);
  if (absolute == null) return null;
  final BigInt? base = header?.isolateDsoBase;
  final BigInt? virtual = match.group(2) == null
      ? (base != null && absolute >= base ? absolute - base : null)
      : BigInt.tryParse(match.group(2)!, radix: 16);
  return RumStackFrame(
    artifactKind: RumArtifactKind.flutterSymbols,
    instructionAddress: _hex(absolute),
    imageAddress: base == null ? null : _hex(base),
    relativeAddress: virtual == null ? null : _hex(virtual),
    debugId: debugId,
    buildId: header?.buildId,
  );
}

/// `#0      Checkout.pay (package:app/checkout.dart:8:5)`
RumStackFrame? _parseDart(String line, String debugId) {
  final RegExpMatch? parenthesized = RegExp(
    r'^#\d+\s+(.+?)\s+\((.+):(\d+):(\d+)\)$',
  ).firstMatch(line);
  if (parenthesized != null) {
    return _sourceFrame(
      debugId: debugId,
      function: parenthesized.group(1),
      file: parenthesized.group(2)!,
      line: int.tryParse(parenthesized.group(3)!),
      column: int.tryParse(parenthesized.group(4)!),
    );
  }
  final RegExpMatch? bare = RegExp(
    r'^#\d+\s+(.+):(\d+):(\d+)$',
  ).firstMatch(line);
  if (bare == null) return null;
  return _sourceFrame(
    debugId: debugId,
    file: bare.group(1)!,
    line: int.tryParse(bare.group(2)!),
    column: int.tryParse(bare.group(3)!),
  );
}

/// `at minified (https://cdn.example.test/main.dart.js:1:2)`
RumStackFrame? _parseWeb(String line, String debugId) {
  final RegExpMatch? match = RegExp(
    r'^(?:at\s+)?(?:(.+?)\s+\()?((?:https?|file):\/\/[^\s\)]+|[^\s\)]+\.(?:js|mjs|cjs|dart)):(\d+):(\d+)\)?$',
  ).firstMatch(line);
  if (match == null) return null;
  return _sourceFrame(
    debugId: debugId,
    function: match.group(1),
    file: match.group(2)!,
    line: int.tryParse(match.group(3)!),
    column: int.tryParse(match.group(4)!),
  );
}

/// `package:app/checkout.dart 8:5  Checkout.pay`
RumStackFrame? _parseStackTracePackage(String line, String debugId) {
  final RegExpMatch? match = RegExp(
    r'^(\S+\.dart)\s+(\d+):(\d+)\s+(.+)$',
  ).firstMatch(line);
  if (match == null) return null;
  return _sourceFrame(
    debugId: debugId,
    function: match.group(4),
    file: match.group(1)!,
    line: int.tryParse(match.group(2)!),
    column: int.tryParse(match.group(3)!),
  );
}

/// A frame that already names a source location. It needs no native artifact
/// on mobile; Flutter Web frames are resolved by file through a source map.
RumStackFrame _sourceFrame({
  required String debugId,
  required String file,
  String? function,
  int? line,
  int? column,
}) => RumStackFrame(
  function: _optional(function),
  file: sanitizeStackFile(file),
  line: _oneBased(line),
  column: _oneBased(column),
  debugId: debugId,
);

RumStackFrame? _parseAndroidNative(
  String line,
  String platform,
  String debugId,
) {
  if (platform != 'android') return null;
  final RegExpMatch? match = RegExp(
    r'^#\d+\s+(?:pc\s+)?([\da-fA-Fx]+)\s+(.+?\.(?:so|elf))(?:\s+\((.+?)(?:\+\d+)?\))?$',
  ).firstMatch(line);
  if (match == null) return null;
  return RumStackFrame(
    artifactKind: RumArtifactKind.androidNativeSymbols,
    module: _basename(sanitizeStackFile(match.group(2)!)),
    function: _optional(match.group(3)),
    relativeAddress: _address(match.group(1)),
    debugId: debugId,
  );
}

RumStackFrame? _parseAppleNative(String line, String platform, String debugId) {
  if (platform != 'ios') return null;
  final RegExpMatch? match = RegExp(
    r'^\d+\s+(\S+)\s+(0x[\da-fA-F]+)\s+(0x[\da-fA-F]+)\s+\+\s+(\d+)',
  ).firstMatch(line);
  if (match == null) return null;
  return RumStackFrame(
    artifactKind: RumArtifactKind.appleDsym,
    module: sanitizeText(match.group(1)!, limit: 256),
    instructionAddress: _address(match.group(2)),
    imageAddress: _address(match.group(3)),
    // The offset into the image is printed in decimal.
    relativeAddress: _decimalAddress(match.group(4)),
    debugId: debugId,
  );
}

String? _optional(String? value) {
  final String normalized = sanitizeText(value?.trim() ?? '', limit: 1024);
  return normalized.isEmpty ? null : normalized;
}

int? _oneBased(int? value) => value == null
    ? null
    : value < 1
    ? 1
    : value;

String _hex(BigInt value) => '0x${value.toRadixString(16)}';

String? _address(String? value) {
  final String normalized = value?.trim() ?? '';
  if (normalized.isEmpty) return null;
  final BigInt? parsed = normalized.toLowerCase().startsWith('0x')
      ? BigInt.tryParse(normalized.substring(2), radix: 16)
      : BigInt.tryParse(normalized, radix: 16) ?? BigInt.tryParse(normalized);
  return parsed == null || parsed.isNegative ? null : _hex(parsed);
}

String? _decimalAddress(String? value) {
  final BigInt? parsed = BigInt.tryParse(value?.trim() ?? '');
  return parsed == null || parsed.isNegative ? null : _hex(parsed);
}

String _basename(String value) {
  final String normalized = value.replaceAll('\\', '/');
  final int slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}
