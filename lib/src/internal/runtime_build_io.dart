import 'dart:io';

String runtimeArchitecture() {
  final RegExpMatch? quoted = RegExp(
    r'\bon\s+"[A-Za-z0-9]+[_-]([A-Za-z0-9_-]+)"',
  ).firstMatch(Platform.version);
  if (quoted != null) return quoted.group(1)!;

  final String executable = Platform.resolvedExecutable.toLowerCase();
  for (final String candidate in <String>[
    'arm64',
    'aarch64',
    'x86_64',
    'x64',
    'armv7',
    'x86',
  ]) {
    if (executable.contains(candidate)) return candidate;
  }
  return 'unknown';
}
