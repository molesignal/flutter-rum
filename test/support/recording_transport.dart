import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';

import 'contract.dart';

bool _reportedSkip = false;

/// Records every upload.
///
/// Each event batch is checked against the event contract, and the test fails
/// at its end if any event broke it, so every test that sends events also
/// verifies their shape. The check is skipped, with the reason on the console,
/// when the contract cannot be found.
class RecordingTransport extends RumTransport {
  RecordingTransport({this.respond, bool validate = true}) {
    if (validate) addTearDown(expectContract);
  }

  /// Answers a request; by default every event is accepted.
  final FutureOr<RumTransportResponse> Function(RumTransportRequest request)?
  respond;
  final List<RumTransportRequest> requests = <RumTransportRequest>[];
  final List<String> violations = <String>[];

  @override
  Future<RumTransportResponse> send(RumTransportRequest request) async {
    requests.add(request);
    int count = 0;
    if (request.kind == RumUploadKind.events) {
      count = _check(request);
    }
    final FutureOr<RumTransportResponse> Function(RumTransportRequest)? custom =
        respond;
    if (custom != null) return custom(request);
    return RumTransportResponse(
      ok: true,
      status: 202,
      body: jsonEncode(<String, Object?>{
        'accepted': count,
        'rejected': <Object?>[],
      }),
    );
  }

  List<RumTransportRequest> get eventRequests => requests
      .where(
        (RumTransportRequest request) => request.kind == RumUploadKind.events,
      )
      .toList(growable: false);

  List<RumTransportRequest> get replayRequests => requests
      .where(
        (RumTransportRequest request) => request.kind == RumUploadKind.replay,
      )
      .toList(growable: false);

  /// Every event sent so far, in upload order.
  List<Map<String, dynamic>> get events =>
      eventRequests.expand(decodeEvents).toList(growable: false);

  List<Map<String, dynamic>> eventsOf(String type) => events
      .where((Map<String, dynamic> event) => event['type'] == type)
      .toList(growable: false);

  /// The highest revision of each view, as the receiver would keep them.
  List<Map<String, dynamic>> get latestViews {
    final Map<String, Map<String, dynamic>> latest =
        <String, Map<String, dynamic>>{};
    for (final Map<String, dynamic> event in eventsOf('view')) {
      final Map<String, dynamic> view = event['view']! as Map<String, dynamic>;
      final String id = view['id']! as String;
      final Map<String, dynamic>? existing = latest[id];
      if (existing == null ||
          (existing['view']! as Map<String, dynamic>)['revision']! as int <
              (view['revision']! as int)) {
        latest[id] = event;
      }
    }
    return latest.values.toList(growable: false);
  }

  void expectContract() {
    if (contractSkipReason != null) {
      if (!_reportedSkip) {
        _reportedSkip = true;
        // ignore: avoid_print
        print('contract validation skipped: $contractSkipReason');
      }
      return;
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  }

  int _check(RumTransportRequest request) {
    if (request.url.path != '/api/v1/rum/events') {
      violations.add('events were sent to ${request.url.path}');
    }
    if (!(request.headers['authorization'] ?? '').startsWith('Bearer mspat-')) {
      violations.add('missing Bearer application token');
    }
    final Object? decoded = jsonDecode(request.body);
    if (decoded is! List<dynamic>) {
      violations.add('the body is not a JSON array');
      return 0;
    }
    for (int index = 0; index < decoded.length; index += 1) {
      for (final String issue in contractIssues(decoded[index])) {
        violations.add('event #$index: $issue');
      }
      for (final String path in unknownFields(decoded[index])) {
        violations.add('event #$index: field $path is not in the contract');
      }
    }
    return decoded.length;
  }
}

/// The events of one `events` upload, decoded.
List<Map<String, dynamic>> decodeEvents(RumTransportRequest request) =>
    (jsonDecode(request.body) as List<dynamic>)
        .map(
          (dynamic value) =>
              Map<String, dynamic>.from(value as Map<dynamic, dynamic>),
        )
        .toList(growable: false);

/// Reads a nested value: `at(event, 'view.performance.fbc.timestamp')`.
Object? at(Map<String, dynamic> value, String path) {
  Object? current = value;
  for (final String key in path.split('.')) {
    if (current is! Map<dynamic, dynamic>) return null;
    current = current[key];
  }
  return current;
}
