import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:molesignal_flutter/molesignal_flutter.dart';

import 'support/contract.dart';
import 'support/recording_transport.dart';

/// The contract validator used by the other tests must agree with the
/// contract's own fixture manifest, or its verdicts on the SDK's events would
/// mean nothing.
void main() {
  final Directory? directory = contractDirectory;

  group('contract fixtures', () {
    test('the validator accepts every valid fixture and rejects every '
        'invalid one', () {
      final Map<String, dynamic> manifest =
          jsonDecode(
                File(
                  '${directory!.path}/fixtures/manifest.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final List<dynamic> cases = manifest['cases'] as List<dynamic>;
      expect(cases, isNotEmpty);
      for (final dynamic raw in cases) {
        final Map<String, dynamic> entry = raw as Map<String, dynamic>;
        final Object? body = jsonDecode(
          File(
            '${directory.path}/fixtures/${entry['path']}',
          ).readAsStringSync(),
        );
        // A batch fixture is a JSON array whose items are validated one by one.
        final List<Object?> events = entry['batch'] == true
            ? body! as List<Object?>
            : <Object?>[body];
        for (final Object? event in events) {
          final List<String> issues = contractIssues(event);
          expect(
            issues.isEmpty,
            entry['valid'],
            reason: '${entry['path']}: ${issues.join('; ')}',
          );
        }
      }
    });

    test('the recording transport reports what breaks the contract', () async {
      final RecordingTransport transport = RecordingTransport(validate: false);
      await transport.send(
        RumTransportRequest(
          url: Uri.parse('https://rum.example.test/api/v1/rum/events'),
          body: jsonEncode(<Object?>[
            <String, Object?>{'type': 'view'},
            <String, Object?>{
              'type': 'resource',
              'date': 1,
              'source': 'flutter',
              'session': <String, Object?>{'id': 'a'},
              'view': <String, Object?>{'id': 'v'},
              'build_versoin': '1',
              'resource': <String, Object?>{
                'type': 'native',
                'url': 'https://x.test',
                'duration': 1.5,
                'status_cod': 200,
              },
            },
          ]),
          headers: const <String, String>{'authorization': 'Bearer nope'},
          kind: RumUploadKind.events,
        ),
      );

      expect(transport.violations.join('\n'), contains('event #0'));
      expect(transport.violations.join('\n'), contains('event #1'));
      expect(transport.violations.join('\n'), contains('resource/duration'));
      expect(
        transport.violations.join('\n'),
        contains('Bearer application token'),
      );
    });

    test('the manifest lists every fixture file', () {
      final Map<String, dynamic> manifest =
          jsonDecode(
                File(
                  '${directory!.path}/fixtures/manifest.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final Set<String> listed = (manifest['cases'] as List<dynamic>)
          .map(
            (dynamic entry) =>
                (entry as Map<String, dynamic>)['path']! as String,
          )
          .toSet();
      final Set<String> present = <String>{
        for (final String folder in <String>['valid', 'invalid'])
          for (final FileSystemEntity file in Directory(
            '${directory.path}/fixtures/$folder',
          ).listSync())
            if (file.path.endsWith('.json'))
              '$folder/${file.uri.pathSegments.last}',
      };
      expect(listed, present);
    });
  }, skip: contractSkipReason);
}
