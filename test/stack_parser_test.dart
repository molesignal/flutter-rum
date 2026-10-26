import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';
import 'package:molesignal_flutter/src/internal/error_description.dart';

const String _header = '''
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
pid: 6339, tid: 6366, name 1.ui
os: android arch: arm64 comp: yes sim: no
build_id: '5D3B4E0A1FE4A0C7A5F3D6E2B1C0A9F8'
isolate_dso_base: 78e1d9500000, vm_dso_base: 78e1d9500000
isolate_instructions: 78e1d5d000, vm_instructions: 78e1d58000
''';

List<RumStackFrame> _parse(
  String stack, {
  String platform = 'android',
  String debugId = 'build-1',
}) => parseStack(stack, platform: platform, debugId: debugId);

void main() {
  group('Dart AOT stacks (split debug info)', () {
    test('keep the absolute, image-relative and image addresses', () {
      final List<RumStackFrame> frames = _parse('''
$_header    #00 abs 000078e1d9a7b9bf virt 000000000057b9bf _kDartIsolateSnapshotInstructions+0x35a1b
    #01 abs 000078e1d9a7bb2f virt 000000000057bb2f _kDartIsolateSnapshotInstructions+0x35b2f
<asynchronous suspension>
    #02 abs 000078e1d9a7bc00 _kDartVmSnapshotInstructions+0x44
''');

      expect(frames, hasLength(3));
      expect(frames[0].artifactKind, RumArtifactKind.flutterSymbols);
      expect(frames[0].instructionAddress, '0x78e1d9a7b9bf');
      expect(frames[0].imageAddress, '0x78e1d9500000');
      expect(frames[0].relativeAddress, '0x57b9bf');
      expect(frames[0].buildId, '5d3b4e0a1fe4a0c7a5f3d6e2b1c0a9f8');
      expect(frames[0].debugId, 'build-1');
      expect(
        frames[2].relativeAddress,
        '0x57bc00',
        reason: 'without virt, the address minus the image base',
      );
    });

    test('read a trace the Dart runtime really printed', () {
      // From `dart compile exe -S symbols.dwarf` on macOS arm64 (Dart 3.12);
      // `dart pub global run native_stack_traces:decode translate` resolves
      // these frames from the `virt` addresses with the symbols file.
      final List<RumStackFrame> frames = _parse('''
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
pid: 71205, tid: 6103232512, name DartWorker
os: macos arch: arm64 comp: no sim: no
build_id: 'b4485c2e7c8fbf8f97e466d0a9a4bcf4'
isolate_dso_base: 10941c000, vm_dso_base: 10941c000
isolate_instructions: 10942c000, vm_instructions: 109420000
    #00 abs 0000000109460eaf virt 0000000000044eaf _kDartIsolateSnapshotInstructions+0x34eaf
    #01 abs 000000010946c28b virt 000000000005028b _kDartIsolateSnapshotInstructions+0x4028b
<asynchronous suspension>
    #02 abs 000000010946c22f virt 000000000005022f _kDartIsolateSnapshotInstructions+0x4022f
<asynchronous suspension>
''', platform: 'flutter');

      expect(frames, hasLength(3));
      expect(frames[0].instructionAddress, '0x109460eaf');
      expect(frames[0].imageAddress, '0x10941c000');
      expect(frames[0].relativeAddress, '0x44eaf');
      expect(frames[0].buildId, 'b4485c2e7c8fbf8f97e466d0a9a4bcf4');
      expect(frames[2].relativeAddress, '0x5022f');
      for (final RumStackFrame frame in frames) {
        // abs - isolate_dso_base == virt, as the runtime prints it.
        expect(
          BigInt.parse(frame.instructionAddress!.substring(2), radix: 16) -
              BigInt.parse(frame.imageAddress!.substring(2), radix: 16),
          BigInt.parse(frame.relativeAddress!.substring(2), radix: 16),
        );
      }
    });

    test('still carry the absolute address when there is no header', () {
      final List<RumStackFrame> frames = _parse(
        '    #00 abs 000078e1d9a7b9bf virt 000000000057b9bf _kDart+0x1\n',
      );
      expect(frames.single.instructionAddress, '0x78e1d9a7b9bf');
      expect(frames.single.relativeAddress, '0x57b9bf');
      expect(frames.single.imageAddress, isNull);
      expect(frames.single.buildId, isNull);
    });

    test('are the same on iOS', () {
      final List<RumStackFrame> frames = _parse(
        '${_header.replaceAll('android', 'ios')}'
        '    #00 abs 0000000104a1b2c4 virt 00000000000b2c4 _kDartIsolateSnapshotInstructions+0x10\n',
        platform: 'ios',
      );
      expect(frames.single.artifactKind, RumArtifactKind.flutterSymbols);
      expect(frames.single.relativeAddress, '0xb2c4');
    });
  });

  group('symbolic Dart stacks', () {
    test('become source frames with a package or SDK file', () {
      final List<RumStackFrame> frames = _parse('''
#0      Cart.total (package:app/cart.dart:12:7)
#1      _rootRunUnary (dart:async/zone.dart:1407:47)
#2      main.<anonymous closure> (file:///Users/alice/work/app/lib/main.dart:3:1)
#3      /Users/alice/work/app/lib/bare.dart:9:2
<asynchronous suspension>
''');

      expect(frames, hasLength(4));
      expect(frames[0].function, 'Cart.total');
      expect(frames[0].file, 'package:app/cart.dart');
      expect(frames[0].line, 12);
      expect(frames[0].column, 7);
      expect(frames[0].artifactKind, isNull, reason: 'already readable');
      expect(frames[1].file, 'dart:async/zone.dart');
      expect(frames[2].function, 'main.<anonymous closure>');
      expect(frames[2].file, 'lib/main.dart', reason: 'no developer paths');
      expect(frames[3].file, 'lib/bare.dart');
      expect(frames[3].function, isNull);
    });

    test('are numbered from one', () {
      final RumStackFrame frame = _parse('#0 f (package:a/a.dart:0:0)').single;
      expect(frame.line, 1);
      expect(frame.column, 1);
    });

    test('are read in the package:stack_trace format too', () {
      final RumStackFrame frame = _parse(
        'package:app/cart.dart 12:7  Cart.total',
      ).single;
      expect(frame.file, 'package:app/cart.dart');
      expect(frame.function, 'Cart.total');
      expect(frame.line, 12);
    });

    test('are cut at 100 frames', () {
      final String stack = <String>[
        for (int i = 0; i < 250; i += 1) '#$i f$i (package:a/a.dart:$i:1)',
      ].join('\n');
      expect(_parse(stack), hasLength(100));
    });
  });

  group('web stacks', () {
    test('name a file and no native artifact', () {
      final List<RumStackFrame> frames = _parse(
        'Error: boom\n'
        '    at minified (https://cdn.example.test/main.dart.js?token=x:10:20)\n'
        '    at https://cdn.example.test/main.dart.js:3:4\n',
        platform: 'flutter',
      );
      expect(frames, hasLength(2));
      expect(frames[0].function, 'minified');
      expect(frames[0].file, 'https://cdn.example.test/main.dart.js');
      expect(frames[0].line, 10);
      expect(frames[0].column, 20);
      expect(frames[0].artifactKind, isNull);
      expect(frames[1].function, isNull);
    });
  });

  group('native stacks', () {
    test('Android lines carry the module and the relative address', () {
      final RumStackFrame frame = _parse(
        '#00 pc 0000000000012345 /data/app/~~x/lib/arm64/libpayments.so (payments_crash+12)',
      ).single;
      expect(frame.artifactKind, RumArtifactKind.androidNativeSymbols);
      expect(frame.module, 'libpayments.so');
      expect(frame.function, 'payments_crash');
      expect(frame.relativeAddress, '0x12345');
    });

    test('Apple lines carry the module and all three addresses', () {
      final RumStackFrame frame = _parse(
        '0   Runner   0x0000000104a1b2c4 0x0000000104a00000 + 111300',
        platform: 'ios',
      ).single;
      expect(frame.artifactKind, RumArtifactKind.appleDsym);
      expect(frame.module, 'Runner');
      expect(frame.instructionAddress, '0x104a1b2c4');
      expect(frame.imageAddress, '0x104a00000');
      expect(frame.relativeAddress, '0x1b2c4');
    });

    test('are only read on their own platform', () {
      expect(_parse('0   Runner   0x1 0x2 + 3', platform: 'android'), isEmpty);
      expect(_parse('#00 pc 0000 /lib/libx.so', platform: 'ios'), isEmpty);
    });
  });

  group('describeError', () {
    test('uses the error type, message and stack', () {
      final ErrorDescription description = describeError(
        FormatException('bad input at https://x.test/a?token=secret'),
        StackTrace.fromString('#0 f (package:a/a.dart:1:2)'),
        platform: 'android',
        debugId: 'b',
      );
      expect(description.type, 'FormatException');
      expect(description.message, contains('bad input'));
      expect(description.message, isNot(contains('token=secret')));
      expect(description.frames, hasLength(1));
      expect(description.stackText, contains('#0 f'));
      expect(description.wasTruncated, isFalse);
    });

    test('falls back to the stack of an Error object', () {
      final StateError error = _thrown();
      final ErrorDescription description = describeError(
        error,
        null,
        platform: 'android',
        debugId: 'b',
      );
      expect(description.frames, isNotEmpty);
    });

    test('never produces an empty message', () {
      final ErrorDescription description = describeError(
        _Silent(),
        null,
        platform: 'android',
        debugId: 'b',
      );
      expect(description.message, '_Silent');
      expect(description.stackText, isNull);
    });

    test('says when frames or text were cut', () {
      final String long = <String>[
        for (int i = 0; i < 150; i += 1) '#$i f (package:a/a.dart:1:1)',
      ].join('\n');
      expect(
        describeError(
          'x',
          StackTrace.fromString(long),
          platform: 'android',
          debugId: 'b',
        ).wasTruncated,
        isTrue,
      );
    });
  });

  group('renderFrames', () {
    test('writes one line per frame', () {
      expect(
        renderFrames(const <RumStackFrame>[
          RumStackFrame(
            function: 'a',
            file: 'package:x/a.dart',
            line: 3,
            column: 4,
          ),
          RumStackFrame(file: 'b.dart', line: 5),
          RumStackFrame(module: 'libx.so', relativeAddress: '0x10'),
          RumStackFrame(instructionAddress: '0x1'),
          RumStackFrame(),
        ]),
        '    at a (package:x/a.dart:3:4)\n'
        '    at b.dart:5\n'
        '    at libx.so (0x10)\n'
        '    at 0x1\n'
        '    at <unknown>',
      );
    });
  });
}

StateError _thrown() {
  try {
    throw StateError('thrown');
  } on StateError catch (error) {
    return error;
  }
}

final class _Silent {
  @override
  String toString() => '';
}
