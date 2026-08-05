import 'dart:async';

import 'package:http/http.dart' as http;

import '../client.dart';
import '../internal/trace_context.dart';
import '../internal/transport_error.dart';
import '../models.dart';

/// A composable `package:http` client that records outgoing resources.
final class MoleSignalHttpClient extends http.BaseClient {
  MoleSignalHttpClient(this.rum, {http.Client? inner, this.closeInner = true})
    : _inner = inner ?? http.Client();

  final MoleSignalRumClient rum;
  final http.Client _inner;
  final bool closeInner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!rum.resourceTrackingEnabled ||
        rum.isSdkUrl(request.url) ||
        !rum.shouldTrackUrl(request.url)) {
      return _inner.send(request);
    }

    final Stopwatch stopwatch = Stopwatch()..start();
    final String? requestTraceparent = _header(request.headers, 'traceparent');
    try {
      final http.StreamedResponse response = await _inner.send(request);
      final RumTraceContext? traceContext = rum.shouldReadTrace(request.url)
          ? parseTraceparent(_header(response.headers, 'traceparent')) ??
                parseTraceparent(
                  traceparentFromServerTiming(
                    _header(response.headers, 'server-timing'),
                  ),
                ) ??
                parseTraceparent(requestTraceparent)
          : null;
      int responseBytes = 0;
      bool finished = false;

      void finish({NormalizedTransportError? error, bool cancelled = false}) {
        if (finished) return;
        finished = true;
        stopwatch.stop();
        final bool httpError = response.statusCode >= 400;
        rum.addResource(
          RumResource(
            method: request.method,
            url: request.url,
            duration: stopwatch.elapsed,
            status: response.statusCode,
            requestSize: request.contentLength,
            responseSize: responseBytes,
            traceContext: traceContext,
            initiator: 'package:http',
            errorType: error?.type ?? (httpError ? 'http' : null),
            errorCode:
                error?.code ??
                (httpError ? 'http_${response.statusCode}' : null),
            errorMessage: error?.message,
            context: <String, Object?>{
              'body_completed': !cancelled && error == null,
            },
          ),
        );
      }

      late final StreamController<List<int>> controller;
      StreamSubscription<List<int>>? subscription;
      controller = StreamController<List<int>>(
        sync: true,
        onListen: () {
          subscription = response.stream.listen(
            (List<int> chunk) {
              responseBytes += chunk.length;
              controller.add(chunk);
            },
            onError: (Object error, StackTrace stackTrace) {
              finish(error: normalizeTransportError(error));
              controller.addError(error, stackTrace);
            },
            onDone: () {
              finish();
              unawaited(controller.close());
            },
            cancelOnError: false,
          );
        },
        onPause: () => subscription?.pause(),
        onResume: () => subscription?.resume(),
        onCancel: () async {
          await subscription?.cancel();
          finish(
            error: const NormalizedTransportError(
              'cancel',
              'cancelled',
              'response body consumption cancelled',
            ),
            cancelled: true,
          );
        },
      );

      return http.StreamedResponse(
        controller.stream,
        response.statusCode,
        contentLength: response.contentLength,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } on Object catch (error, stackTrace) {
      stopwatch.stop();
      final NormalizedTransportError normalized = normalizeTransportError(
        error,
      );
      rum.addResource(
        RumResource(
          method: request.method,
          url: request.url,
          duration: stopwatch.elapsed,
          requestSize: request.contentLength,
          traceContext: rum.shouldReadTrace(request.url)
              ? parseTraceparent(requestTraceparent)
              : null,
          initiator: 'package:http',
          errorType: normalized.type,
          errorCode: normalized.code,
          errorMessage: normalized.message,
          context: const <String, Object?>{'body_completed': false},
        ),
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  void close() {
    if (closeInner) _inner.close();
  }
}

String? _header(Map<String, String> headers, String name) {
  final String lowerName = name.toLowerCase();
  for (final MapEntry<String, String> entry in headers.entries) {
    if (entry.key.toLowerCase() == lowerName) return entry.value;
  }
  return null;
}
