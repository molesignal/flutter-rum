import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/src/internal/sdk_info.dart';

/// The version appears in the package, in every event, in the install snippets
/// and in the changelog; they must not drift apart.
void main() {
  final String pubspec = File('pubspec.yaml').readAsStringSync();
  final String version = RegExp(
    r'^version:\s*(\S+)',
    multiLine: true,
  ).firstMatch(pubspec)!.group(1)!;

  test('sdk.version is the package version', () {
    expect(sdkVersion, version);
    expect(sdkName, 'molesignal_flutter');
    expect(
      RegExp(
        r'^name:\s*molesignal_flutter$',
        multiLine: true,
      ).hasMatch(pubspec),
      isTrue,
    );
  });

  test('the install snippets and the changelog name the same version', () {
    for (final String readme in <String>['README.md', 'README.zh-CN.md']) {
      expect(
        File(readme).readAsStringSync(),
        contains('molesignal_flutter: ^$version'),
        reason: readme,
      );
    }
    expect(File('CHANGELOG.md').readAsStringSync(), contains('## $version'));
  });
}
