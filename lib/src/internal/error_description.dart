import '../models.dart';
import 'sanitization.dart';

final class ErrorDescription {
  const ErrorDescription({
    required this.type,
    required this.message,
    required this.stack,
    this.rawStack,
  });

  final String type;
  final String message;
  final List<RumStackFrame> stack;
  final String? rawStack;
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
  final String? rawStack = originalStack == null
      ? null
      : sanitizeStackText(originalStack);
  return ErrorDescription(
    type: sanitizeText(error.runtimeType.toString(), limit: 256),
    message: sanitizeText(error.toString()),
    stack: originalStack == null
        ? const <RumStackFrame>[]
        : parseStack(originalStack, platform: platform, debugId: debugId),
    rawStack: rawStack,
  );
}

List<RumStackFrame> parseStack(
  String stack, {
  required String platform,
  required String debugId,
}) {
  final List<RumStackFrame> frames = <RumStackFrame>[];
  for (final String rawLine in stack.split('\n').take(100)) {
    final String line = rawLine.trim();
    if (line.isEmpty || line == '<asynchronous suspension>') continue;

    final RumStackFrame? native =
        _parseAndroidNative(line, platform, debugId) ??
        _parseAppleNative(line, platform, debugId);
    if (native != null) {
      frames.add(native);
      continue;
    }

    final RegExpMatch? parenthesizedMatch = RegExp(
      r'^#\d+\s+(.+?)\s+\((.+):(\d+):(\d+)\)$',
    ).firstMatch(line);
    if (parenthesizedMatch != null) {
      frames.add(
        _dartOrWebFrame(
          platform: platform,
          debugId: debugId,
          function: parenthesizedMatch.group(1),
          file: parenthesizedMatch.group(2)!,
          line: int.tryParse(parenthesizedMatch.group(3)!),
          column: int.tryParse(parenthesizedMatch.group(4)!),
        ),
      );
      continue;
    }

    final RegExpMatch? webMatch = RegExp(
      r'^(?:at\s+)?(?:(.+?)\s+\()?((?:https?|file):\/\/[^\s\)]+|[^\s\)]+\.(?:js|mjs|cjs|dart)):(\d+):(\d+)\)?$',
    ).firstMatch(line);
    if (webMatch != null) {
      frames.add(
        _dartOrWebFrame(
          platform: platform,
          debugId: debugId,
          function: webMatch.group(1),
          file: webMatch.group(2)!,
          line: int.tryParse(webMatch.group(3)!),
          column: int.tryParse(webMatch.group(4)!),
        ),
      );
      continue;
    }

    final RegExpMatch? bareMatch = RegExp(
      r'^#\d+\s+(.+):(\d+):(\d+)$',
    ).firstMatch(line);
    if (bareMatch != null) {
      frames.add(
        _dartOrWebFrame(
          platform: platform,
          debugId: debugId,
          file: bareMatch.group(1)!,
          line: int.tryParse(bareMatch.group(2)!),
          column: int.tryParse(bareMatch.group(3)!),
        ),
      );
    }
  }
  return frames;
}

RumStackFrame _dartOrWebFrame({
  required String platform,
  required String debugId,
  required String file,
  String? function,
  int? line,
  int? column,
}) => RumStackFrame(
  artifactKind: platform == 'flutter'
      ? RumArtifactKind.javascriptSourcemap
      : RumArtifactKind.flutterSymbols,
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
    relativeAddress: _address(match.group(4)),
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

String? _address(String? value) {
  final String normalized = value?.trim() ?? '';
  if (normalized.isEmpty) return null;
  final int? parsed = normalized.toLowerCase().startsWith('0x')
      ? int.tryParse(normalized.substring(2), radix: 16)
      : int.tryParse(normalized, radix: 16) ?? int.tryParse(normalized);
  return parsed == null || parsed < 0 ? null : '0x${parsed.toRadixString(16)}';
}

String _basename(String value) {
  final String normalized = value.replaceAll('\\', '/');
  final int slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}
