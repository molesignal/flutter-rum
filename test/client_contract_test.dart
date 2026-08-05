import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molesignal_flutter/molesignal_flutter.dart';

const String _clientToken =
    'msrum_aB3kZ1xT9pQrU7nM_dFgHjKl8eRvNcWxYz4tBmEqPaS2vG6Qz';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('validates required configuration', () async {
    await expectLater(
      initRum(
        RumConfiguration(
          applicationId: '',
          clientToken: 'invalid',
          site: 'https://rum.example.test',
          persistence: MemoryRumPersistence(),
        ),
      ),
      throwsArgumentError,
    );
    await expectLater(
      initRum(
        RumConfiguration(
          applicationId: 'app',
          clientToken: _clientToken,
          site: 'ftp://rum.example.test',
          persistence: MemoryRumPersistence(),
        ),
      ),
      throwsArgumentError,
    );
  });

  test('sessions, actions, and errors follow the ingest contract', () async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient client = await initRum(
      _configuration(
        transport,
        user: const RumUser(
          id: 'user-42',
          attributes: <String, Object?>{'plan': 'pro'},
        ),
        globalContext: const <String, Object?>{'region': 'ap-southeast-1'},
      ),
    );
    addTearDown(client.stop);

    client.startView('Products', path: '/products?secret=hidden');
    client.addAction(
      'Checkout started',
      context: const <String, Object?>{
        'cart_size': 3,
        'password': 'must-not-leak',
      },
    );
    client.addError(
      StateError('Cannot read total'),
      stackTrace: StackTrace.fromString(
        '#0 Cart.total (package:app/cart.dart:12:7)',
      ),
      context: const <String, Object?>{'component': 'CartSummary'},
    );
    await client.flush();

    final RumTransportRequest sessionRequest = transport.only(
      RumEventKind.session,
    );
    expect(
      sessionRequest.url.toString(),
      'https://rum.example.test/api/v1/rum/sessions',
    );
    expect(sessionRequest.headers['authorization'], 'Bearer $_clientToken');
    expect(
      sessionRequest.headers['x-molesignal-application-id'],
      'checkout-mobile',
    );
    final Map<String, dynamic> session = _events(sessionRequest).single;
    expect(session['session_id'], startsWith('ses_'));
    expect(session['application'], 'checkout-mobile');
    expect(session['service'], 'checkout-app');
    expect(session['environment'], 'production');
    expect(session['version'], '1.2.3+4');
    expect(session['user_id'], 'user-42');
    expect(session['landing_page'], '/products');
    expect(session['started_at_micros'], isA<int>());

    final List<Map<String, dynamic>> actions = transport
        .matching(RumEventKind.action)
        .expand(_events)
        .toList(growable: false);
    final Map<String, dynamic> custom = actions.firstWhere(
      (Map<String, dynamic> event) => event['name'] == 'Checkout started',
    );
    final Map<String, dynamic> payload = Map<String, dynamic>.from(
      custom['payload']! as Map<dynamic, dynamic>,
    );
    expect(custom['type'], 'custom');
    expect(custom['page'], '/products');
    expect(payload['region'], 'ap-southeast-1');
    expect(payload['cart_size'], 3);
    expect(payload['password'], '[Redacted]');

    final RumTransportRequest errorRequest = transport.only(RumEventKind.error);
    final Map<String, dynamic> error = _events(errorRequest).single;
    expect(error['error_type'], 'StateError');
    expect(error['message'], contains('Cannot read total'));
    expect(error['fingerprint'], matches(RegExp(r'^fp_[0-9a-f]{8}$')));
    final Map<String, dynamic> errorDetails = Map<String, dynamic>.from(
      error['error']! as Map<dynamic, dynamic>,
    );
    expect(errorDetails['stack'], isNotEmpty);
    expect(errorDetails.containsKey('raw_stack'), isFalse);
    final Map<String, dynamic> errorContext = Map<String, dynamic>.from(
      errorDetails['context']! as Map<dynamic, dynamic>,
    );
    expect(errorContext['component'], 'CartSummary');

    await client.stop();
  });

  test('beforeSend can mutate and drop actions', () async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient client = await initRum(
      _configuration(
        transport,
        beforeSend: (RumContext event, RumBeforeSendContext context) {
          if (context.kind == RumEventKind.action &&
              event['name'] == 'Drop me') {
            return false;
          }
          event['processed'] = true;
          return true;
        },
      ),
    );
    addTearDown(client.stop);

    client.addAction('Keep me');
    client.addAction('Drop me');
    await client.flush();

    final List<Map<String, dynamic>> actions = transport
        .matching(RumEventKind.action)
        .expand(_events)
        .toList(growable: false);
    expect(
      actions.map((Map<String, dynamic> event) => event['name']),
      <String?>['Keep me'],
    );
    expect(actions.single['processed'], isTrue);

    await client.stop();
  });

  test('retryable failures preserve queued payloads', () async {
    final RetryActionTransport transport = RetryActionTransport();
    final MoleSignalRumClient client = await initRum(_configuration(transport));
    addTearDown(client.stop);

    client.addAction('Retry me');
    await client.flush();
    await client.flush();

    final List<RumTransportRequest> attempts = transport.matching(
      RumEventKind.action,
    );
    expect(attempts, hasLength(2));
    expect(jsonDecode(attempts[0].body), jsonDecode(attempts[1].body));

    await client.stop();
  });

  test('zero sampling emits no events', () async {
    final RecordingTransport transport = RecordingTransport();
    final MoleSignalRumClient client = await initRum(
      _configuration(transport, sessionSampleRate: 0),
    );
    addTearDown(client.stop);

    client.startView('Home', path: '/');
    client.addAction('Ignored');
    client.addError(StateError('Ignored'));
    await client.flush();

    expect(transport.requests, isEmpty);
    expect(client.getInternalContext().sessionId, isNull);
    await client.stop();
  });
}

RumConfiguration _configuration(
  RumTransport transport, {
  RumUser? user,
  RumContext globalContext = const <String, Object?>{},
  RumBeforeSend? beforeSend,
  double sessionSampleRate = 100,
}) => RumConfiguration(
  applicationId: 'checkout-mobile',
  clientToken: _clientToken,
  site: 'https://rum.example.test',
  service: 'checkout-app',
  env: 'production',
  version: '1.2.3+4',
  user: user,
  globalContext: globalContext,
  sessionSampleRate: sessionSampleRate,
  trackFlutterErrors: false,
  trackPlatformErrors: false,
  trackAppLifecycle: false,
  trackLongFrames: false,
  trackAnonymousUser: false,
  flushInterval: const Duration(minutes: 1),
  beforeSend: beforeSend,
  transport: transport,
  persistence: MemoryRumPersistence(),
);

List<Map<String, dynamic>> _events(RumTransportRequest request) {
  final List<dynamic> decoded = jsonDecode(request.body) as List<dynamic>;
  return decoded
      .map(
        (dynamic value) =>
            Map<String, dynamic>.from(value as Map<dynamic, dynamic>),
      )
      .toList(growable: false);
}

class RecordingTransport extends RumTransport {
  final List<RumTransportRequest> requests = <RumTransportRequest>[];

  @override
  Future<RumTransportResponse> send(RumTransportRequest request) async {
    requests.add(request);
    return const RumTransportResponse(ok: true, status: 200);
  }

  List<RumTransportRequest> matching(RumEventKind kind) => requests
      .where((RumTransportRequest request) => request.kind == kind)
      .toList(growable: false);

  RumTransportRequest only(RumEventKind kind) {
    final List<RumTransportRequest> values = matching(kind);
    expect(values, hasLength(1));
    return values.single;
  }
}

final class RetryActionTransport extends RecordingTransport {
  bool _rejected = false;

  @override
  Future<RumTransportResponse> send(RumTransportRequest request) async {
    requests.add(request);
    if (request.kind == RumEventKind.action && !_rejected) {
      _rejected = true;
      return const RumTransportResponse(ok: false, status: 503);
    }
    return const RumTransportResponse(ok: true, status: 200);
  }
}
